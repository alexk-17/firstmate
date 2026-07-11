#!/usr/bin/env bash
# fm-dock-tui-lib.sh - the PURE, testable core of the Fleet Dock full-screen TUI.
#
# The TUI (bin/fm-dock.sh, default interactive mode on a capable tty) splits into
# two layers so the fragile part stays tiny. Everything here is PURE: each
# function's output is a deterministic function of its arguments alone - it does
# NO terminal I/O, reads no state files, and touches no globals it was not
# passed. The impure raw-mode input/refresh loop and the escape-sequence
# emission live in fm-dock.sh and are deliberately NOT unit-tested; this library
# is (tests/fm-dock-tui.test.sh).
#
# What is pure and tested here:
#   render        fm_dock_render_list / fm_dock_render_detail turn a fleet-status
#                 JSON projection (+ inbox array, selection index, width, color,
#                 clock stamp, flash) into the exact screen string.
#   selection     fm_dock_actionable_ids / _count / _nth_id / _clamp_sel /
#                 _move_sel are the cursor state machine over the actionable list
#                 (NEEDS YOU ++ AT RISK ++ RUNNING, in that fixed order - the same
#                 order and projection bin/fm-fleet-status.sh emits; never
#                 re-derived).
#   dispatch      fm_dock_action_for_key maps a single keystroke to an inbox
#                 action; _action_needs_payload / _action_is_destructive gate the
#                 payload prompt and the destructive-confirm modal.
#
# The action names produced here are exactly the inbox actions
# (bin/fm-inbox-lib.sh); the loop feeds them straight into fm-dock.sh's existing
# validated write_intent path. The TUI never writes an intent any other way and
# never touches a backend - it only renders read-only state and queues intents.
# jq is required by the render functions (the caller checks once).

# --- selection state machine (pure) ----------------------------------------

# The actionable task ids, in cursor order: NEEDS YOU, then AT RISK, then
# RUNNING - identical to fm-fleet-status.sh's projection order (RECENTLY DONE is
# not actionable and is never included).
fm_dock_actionable_ids() {  # <status_json>
  printf '%s' "$1" \
    | jq -r '[.sections.needs_you[]?, .sections.at_risk[]?, .sections.running[]?] | .[].id' 2>/dev/null
}

fm_dock_actionable_count() {  # <status_json>
  local n
  n=$(fm_dock_actionable_ids "$1" | grep -c . 2>/dev/null)
  printf '%s' "${n:-0}"
}

# The id at cursor <index> (0-based), or nothing when out of range.
fm_dock_nth_id() {  # <status_json> <index>
  local idx=$2
  case "$idx" in ''|*[!0-9]*) return 1 ;; esac
  fm_dock_actionable_ids "$1" | sed -n "$((idx + 1))p"
}

# Clamp a selection index into [0, count-1]; 0 when the list is empty.
fm_dock_clamp_sel() {  # <sel> <count>
  local sel=$1 count=$2
  case "$sel" in ''|*[!0-9]*) sel=0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -le 0 ]; then printf '0'; return 0; fi
  [ "$sel" -lt 0 ] && sel=0
  [ "$sel" -ge "$count" ] && sel=$((count - 1))
  printf '%s' "$sel"
}

# Move the cursor up or down one row, clamped at the ends (no wrap).
fm_dock_move_sel() {  # <sel> <count> <up|down>
  local sel=$1 count=$2 dir=$3
  case "$sel" in ''|*[!0-9]*) sel=0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -le 0 ]; then printf '0'; return 0; fi
  case "$dir" in
    up)   sel=$((sel - 1)); [ "$sel" -lt 0 ] && sel=0 ;;
    down) sel=$((sel + 1)); [ "$sel" -ge "$count" ] && sel=$((count - 1)) ;;
  esac
  printf '%s' "$sel"
}

# --- key -> action dispatch (pure) ------------------------------------------

# Map a single keystroke to an inbox action, or empty when the key is not an
# action key. Kept in lockstep with fm-inbox-lib.sh's action allowlist; the
# footer keymap in the renderers documents the same bindings.
fm_dock_action_for_key() {  # <key>
  case "$1" in
    a) printf 'answer' ;;
    n) printf 'note' ;;
    m) printf 'merge' ;;
    p) printf 'peek' ;;
    i) printf 'interrupt' ;;
    t) printf 'teardown' ;;
    *) printf '' ;;
  esac
}

# 0 iff the action needs a payload line (answer/note); mirrors validate_submission.
fm_dock_action_needs_payload() {  # <action>
  case "$1" in answer|note) return 0 ;; *) return 1 ;; esac
}

# 0 iff the action is destructive/disruptive and must show a confirm modal before
# the intent is queued. firstmate + the captain still gate real execution.
fm_dock_action_is_destructive() {  # <action>
  case "$1" in merge|teardown|interrupt) return 0 ;; *) return 1 ;; esac
}

# --- shared jq render prelude -----------------------------------------------
# Color/paint/clip/glyph/phase-color helpers reused by both renderers. Kept as a
# jq string so each (separate) jq invocation compiles the same helpers. The $vars
# below are jq variables, not shell - the single quotes are intentional.
# shellcheck disable=SC2016
FM_DOCK_JQ_PRELUDE='
  def esc($c): if $color then "\u001b[\($c)m" else "" end;
  def reset: esc("0");
  def paint($c; $s): esc($c) + $s + reset;
  def clip($s): ($s // "") | if (. | length) > $width then (.[0:($width - 1)] + "…") else . end;
  def glyph($h):
    if $h == "active" then "●" elif $h == "idle" then "○"
    elif $h == "stale" then "▲" elif $h == "dead" then "✖" else "?" end;
  def hcol($h):
    if $h == "dead" then "31" elif $h == "stale" then "33"
    elif $h == "active" then "32" else "2" end;
  def pcol($p):
    if $p == "failed" or $p == "blocked" then "31"
    elif $p == "needs-decision" then "33" elif $p == "paused" then "35"
    elif $p == "ready" or $p == "done" then "32" elif $p == "validating" then "36"
    elif $p == "working" then "34" else "2" end;
  def istat($s):
    if $s == "pending" then "33" elif $s == "claimed" then "36"
    elif $s == "done" then "32" elif $s == "rejected" or $s == "error" then "31"
    else "2" end;
'

# --- list view render (pure) ------------------------------------------------

# Render the full-screen list: header (home + clock + refresh cadence), the four
# health-coded sections with the cursor marker on row <sel>, the inbox strip, an
# optional flash line, and the footer keymap. Deterministic given its args.
fm_dock_render_list() {  # <status_json> <sel> <width> <color> <stamp> <refresh> [inbox_json] [flash]
  local sjson=$1 sel=$2 width=$3 color=$4 stamp=$5 refresh=$6 inbox=${7:-[]} flash=${8:-}
  case "$sel" in ''|*[!0-9]*) sel=0 ;; esac
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  [ "$width" -ge 20 ] || width=20
  printf '%s' "$sjson" | jq -r \
    --argjson sel "$sel" --argjson width "$width" --argjson color "$color" \
    --arg stamp "$stamp" --arg refresh "$refresh" --argjson inbox "$inbox" --arg flash "$flash" \
    "$FM_DOCK_JQ_PRELUDE"'
    def arow($r; $g):
      (if $g == $sel then paint("1;36"; "›") else " " end) as $cur
      | ($cur + " " + paint("1"; $r.id) + "  "
         + paint(hcol($r.health); glyph($r.health))
         + " " + paint(pcol($r.phase); ($r.phase // "-"))
         + " " + esc("2") + "·" + reset + " " + ($r.owner // "-")
         + " " + esc("2") + "· " + ($r.freshness.age // "-") + reset)
        + "\n     " + esc("2") + clip($r.next_action // $r.headline // "-") + reset;
    def sec($rows; $off; $title; $code; $empty):
      [ paint($code + ";1"; $title) + paint("2"; "  (\($rows | length))") ]
      + (if ($rows | length) == 0 then [ "  " + esc("2") + $empty + reset ]
         else [ $rows | to_entries[] | arow(.value; $off + .key) ] end)
      + [ "" ];
    def donerow($r):
      "  " + paint("1"; ($r.id // "-")) + "  "
      + esc("2") + clip(($r.title // "-") + "  [" + ($r.repo // "-") + "] " + ($r.artifact // "-")) + reset;
    (.sections.needs_you // []) as $ny
    | (.sections.at_risk // []) as $ar
    | (.sections.running // []) as $ru
    | (.sections.recently_done // []) as $rd
    | ($ny | length) as $n1 | ($ar | length) as $n2
    | ([ paint("1;36"; "Fleet Dock") + "  " + esc("2") + (.fm_home // "-") + reset
         + "   " + esc("2") + $stamp + " ⟳" + $refresh + "s" + reset, "" ]
       + sec($ny; 0; "NEEDS YOU"; "33"; "Nothing needs you.")
       + sec($ar; $n1; "AT RISK"; "31"; "Nothing at risk.")
       + sec($ru; ($n1 + $n2); "RUNNING"; "36"; "No tasks in flight.")
       + [ paint("32;1"; "RECENTLY DONE") + paint("2"; "  (\($rd | length))") ]
       + (if ($rd | length) == 0 then [ "  " + esc("2") + "No recently completed work." + reset ]
          else [ $rd[] | donerow(.) ] end)
       + [ "",
           (esc("2") + "inbox:" + reset + " "
            + (if ($inbox | length) == 0 then esc("2") + "(empty)" + reset
               else ([ $inbox[] | paint(istat(.status); (.action // "?") + "/" + (.task_id // "?")) ] | join("  ")) end)),
           (if $flash == "" then empty else paint("1;37"; "» " + $flash) end),
           paint("2"; "↑/↓ move · enter detail · a answer · n note · m merge · p peek · i interrupt · t teardown · q quit") ])
      | join("\n")
    '
}

# --- detail view render (pure) ----------------------------------------------

# Render the detail card for one task from a detail object assembled by the loop
# (bin/fm-dock.sh's build_detail): identity/config fields, the reconciled live
# state line, the decision text + options when the task is awaiting a decision,
# and a short recent-status tail. Deterministic given its args.
fm_dock_render_detail() {  # <detail_json> <width> <color>
  local djson=$1 width=$2 color=$3
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  [ "$width" -ge 20 ] || width=20
  printf '%s' "$djson" | jq -r \
    --argjson width "$width" --argjson color "$color" \
    "$FM_DOCK_JQ_PRELUDE"'
    def val($v): ($v | if . == "" or . == null then "-" else . end);
    [ paint("1;36"; "Task " + (.id // "-")) + "   " + esc("2") + "esc back · q quit" + reset, "",
      "  project   " + val(.project),
      "  harness   " + val(.harness),
      "  mode      " + val(.mode),
      "  kind      " + val(.kind),
      "  branch    " + val(.branch),
      "  state     " + paint(pcol(.phase // "-"); (.phase // "-"))
        + " " + esc("2") + "·" + reset + " " + (.owner // "-")
        + " " + esc("2") + "·" + reset + " " + paint(hcol(.health // "-"); (.health // "-"))
        + " " + esc("2") + "· " + (.age // "-") + reset,
      (if (.crew_state // "") == "" then empty else "  live      " + esc("2") + clip(.crew_state) + reset end),
      (if .pr_url == null then empty else "  pr        " + .pr_url end),
      "" ]
    + (if (.decision.present // false)
       then [ paint("33;1"; "  DECISION NEEDED"), "  " + clip(.decision.text // "-"), "" ]
       else [] end)
    + [ paint("2"; "  recent status:") ]
    + (if ((.status_tail // []) | length) == 0 then [ "    " + esc("2") + "(none)" + reset ]
       else [ .status_tail[] | "    " + esc("2") + clip(.) + reset ] end)
    + [ "", paint("2"; "  a answer · n note · m merge · p peek · i interrupt · t teardown · esc back · q quit") ]
    | join("\n")
    '
}
