#!/usr/bin/env bash
# fm-dock-tui-lib.sh - the PURE, testable core of the Fleet Dock full-screen TUI.
#
# The TUI (bin/fm-dock.sh, default interactive mode on a capable tty) splits into
# two layers so the fragile part stays tiny. Everything here is PURE: each
# function's output is a deterministic function of its arguments alone - it does
# NO terminal I/O, reads no state files, and touches no globals it was not
# passed. The impure raw-mode input/refresh loop and the escape-sequence
# emission live in fm-dock.sh; those are covered by the pseudo-terminal
# integration tests (tests/fm-dock-tui-pty.test.sh), while this library is
# covered by fm-dock-tui.test.sh.
#
# What is pure and tested here:
#   render        fm_dock_render_list / fm_dock_render_detail turn a fleet-status
#                 JSON projection (+ inbox array, selection index, terminal
#                 width AND height, color, clock stamp, flash) into the exact
#                 screen string, width-clipped and height-bounded to a viewport.
#   selection     fm_dock_selectable_ids / _selectable_count / _nth_id /
#                 _clamp_sel / _move_sel are the cursor state machine. The cursor
#                 moves over NEEDS YOU ++ AT RISK ++ RUNNING ++ RECENTLY DONE, in
#                 that fixed fm-fleet-status.sh order (never re-derived).
#                 fm_dock_actionable_ids / _count / _id_is_actionable are the LIVE
#                 subset (no RECENTLY DONE): a done row is selectable only to view
#                 its detail, and the loop refuses inbox actions on it.
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

# The ACTIONABLE task ids (live work that can take an inbox action), in order:
# NEEDS YOU, then AT RISK, then RUNNING. RECENTLY DONE is NOT actionable (finished
# work takes no answer/note/merge/peek/interrupt/teardown) and is excluded here;
# it is selectable for VIEWING via fm_dock_selectable_ids below.
fm_dock_actionable_ids() {  # <status_json>
  printf '%s' "$1" \
    | jq -r '[.sections.needs_you[]?, .sections.at_risk[]?, .sections.running[]?] | .[].id' 2>/dev/null
}

# The SELECTABLE task ids - the cursor set the arrow keys move over: the
# actionable set PLUS RECENTLY DONE appended last, matching the on-screen order.
fm_dock_selectable_ids() {  # <status_json>
  printf '%s' "$1" \
    | jq -r '[.sections.needs_you[]?, .sections.at_risk[]?, .sections.running[]?, .sections.recently_done[]?] | .[].id' 2>/dev/null
}

# 0 iff <id> is an actionable (live) task; non-zero for a recently-done id. The
# loop allows detail/view on any selected row but refuses inbox actions on a
# completed task.
fm_dock_id_is_actionable() {  # <status_json> <id>
  fm_dock_actionable_ids "$1" | grep -qxF "$2"
}

fm_dock_actionable_count() {  # <status_json>
  local n
  n=$(fm_dock_actionable_ids "$1" | grep -c . 2>/dev/null)
  printf '%s' "${n:-0}"
}

# Count of the SELECTABLE set (the 4 sections) - the cursor's range.
fm_dock_selectable_count() {  # <status_json>
  local n
  n=$(fm_dock_selectable_ids "$1" | grep -c . 2>/dev/null)
  printf '%s' "${n:-0}"
}

# The id at cursor <index> (0-based) over the SELECTABLE set, or nothing when out
# of range.
fm_dock_nth_id() {  # <status_json> <index>
  local idx=$2
  case "$idx" in ''|*[!0-9]*) return 1 ;; esac
  fm_dock_selectable_ids "$1" | sed -n "$((idx + 1))p"
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
#
# fit() is the viewport's width guard: it truncates a single physical line to
# $width VISIBLE columns. In color mode it walks the line as alternating SGR
# escapes (zero width, always kept) and text runs (counted, truncated), so a line
# is never cut mid-escape and a colored line never overflows on visible width.
# clip() adds a semantic ellipsis to one field; fit() is the final hard bound
# applied to EVERY emitted line so the header, footer, urls, and keymaps can
# never overflow the terminal.
# shellcheck disable=SC2016
FM_DOCK_JQ_PRELUDE='
  def esc($c): if $color then "\u001b[\($c)m" else "" end;
  def reset: esc("0");
  def paint($c; $s): esc($c) + $s + reset;
  def clip($s): ($s // "") | if (. | length) > $width then (.[0:($width - 1)] + "…") else . end;
  def fit($s):
    if $color then
      (reduce ([$s | scan("\u001b\\[[0-9;]*m|[^\u001b]+")][]) as $c ({a:"", n:0};
        if ($c | test("^\u001b")) then {a:(.a + $c), n:.n}
        else ($width - .n) as $room
          | if $room <= 0 then . else {a:(.a + $c[0:$room]), n:(.n + ([($c|length), $room] | min))} end
        end)).a + esc("0")
    else ($s // "")[0:$width] end;
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

# Render the full-screen list into a viewport of exactly <= $rows lines and
# <= $width columns per line: a fixed header (home + clock + refresh cadence), the
# four health-coded sections (one line per task, cursor marker on row <sel>), and
# a fixed footer (inbox strip + optional flash + keymap). When the body exceeds
# the height between header and footer, it scrolls to a window that always keeps
# the selected row visible. Deterministic given its args.
fm_dock_render_list() {  # <status_json> <sel> <width> <rows> <color> <stamp> <refresh> [inbox_json] [flash]
  local sjson=$1 sel=$2 width=$3 rows=$4 color=$5 stamp=$6 refresh=$7 inbox=${8:-[]} flash=${9:-}
  case "$sel" in ''|*[!0-9]*) sel=0 ;; esac
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  [ "$width" -ge 20 ] || width=20
  case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
  [ "$rows" -ge 6 ] || rows=6
  printf '%s' "$sjson" | jq -r \
    --argjson sel "$sel" --argjson width "$width" --argjson rows "$rows" --argjson color "$color" \
    --arg stamp "$stamp" --arg refresh "$refresh" --argjson inbox "$inbox" --arg flash "$flash" \
    "$FM_DOCK_JQ_PRELUDE"'
    # One line per task (cursor · id · glyph · phase · owner · age — next action).
    def rowline($r; $g):
      (if $g == $sel then paint("1;36"; "›") else " " end)
      + " " + paint("1"; ($r.id // "-")) + " "
      + paint(hcol($r.health); glyph($r.health))
      + " " + paint(pcol($r.phase); ($r.phase // "-"))
      + " " + esc("2") + "·" + reset + " " + ($r.owner // "-")
      + " " + esc("2") + "· " + ($r.freshness.age // "-") + reset
      + esc("2") + "  — " + ($r.next_action // $r.headline // "-") + reset;
    # A section header plus its rows, as {t:<line>, s:<is-selected-row>} records.
    def secbody($items; $off; $title; $code; $empty):
      [ {t: (paint($code + ";1"; $title) + paint("2"; "  (\($items | length))")), s:false} ]
      + (if ($items | length) == 0 then [ {t: ("  " + esc("2") + $empty + reset), s:false} ]
         else [ $items | to_entries[] | {t: rowline(.value; $off + .key), s: (($off + .key) == $sel)} ] end)
      + [ {t:"", s:false} ];
    def donerow($r; $g):
      (if $g == $sel then paint("1;36"; "›") else " " end)
      + " " + paint("1"; ($r.id // "-")) + "  "
      + esc("2") + (($r.title // "-") + "  [" + ($r.repo // "-") + "] " + ($r.artifact // "-")) + reset;

    (.sections.needs_you // []) as $ny
    | (.sections.at_risk // []) as $ar
    | (.sections.running // []) as $ru
    | (.sections.recently_done // []) as $rd
    | ($ny | length) as $n1 | ($ar | length) as $n2 | ($ru | length) as $n3
    | ([ paint("1;36"; "Fleet Dock") + "  " + esc("2") + (.fm_home // "-") + reset
         + "   " + esc("2") + $stamp + " ⟳" + $refresh + "s" + reset, "" ]) as $head
    | ([ (esc("2") + "inbox:" + reset + " "
          + (if ($inbox | length) == 0 then esc("2") + "(empty)" + reset
             else ([ $inbox[] | paint(istat(.status); (.action // "?") + "/" + (.task_id // "?")) ] | join("  ")) end)) ]
       + (if $flash == "" then [] else [ paint("1;37"; "» " + $flash) ] end)
       + [ paint("2"; "↑↓ move · ⏎ detail · a answer n note m merge p peek i intr t tear · q quit") ]) as $foot
    | (secbody($ny; 0; "NEEDS YOU"; "33"; "Nothing needs you.")
       + secbody($ar; $n1; "AT RISK"; "31"; "Nothing at risk.")
       + secbody($ru; ($n1 + $n2); "RUNNING"; "36"; "No tasks in flight.")
       + [ {t: (paint("32;1"; "RECENTLY DONE") + paint("2"; "  (\($rd | length))")), s:false} ]
       + (if ($rd | length) == 0 then [ {t: ("  " + esc("2") + "No recently completed work." + reset), s:false} ]
          else [ $rd | to_entries[] | {t: donerow(.value; ($n1 + $n2 + $n3) + .key), s: (($n1 + $n2 + $n3 + .key) == $sel)} ] end)) as $body
    # Scroll the body to a window that fits between the header and footer and
    # always contains the selected row.
    | ([$rows - ($head | length) - ($foot | length), 1] | max) as $avail
    | (if ($body | length) <= $avail then $body
       else
         ([ $body | to_entries[] | select(.value.s) | .key ] | (.[0] // 0)) as $seli
         | ([ [$seli - (($avail / 2) | floor), 0] | max, ($body | length) - $avail ] | min) as $start
         | $body[$start : $start + $avail]
       end) as $win
    | ($head + [ $win[].t ] + $foot) | map(fit(.)) | join("\n")
    '
}

# --- detail view render (pure) ----------------------------------------------

# Render the detail card for one task from a detail object assembled by the loop
# (bin/fm-dock.sh's build_detail): identity/config fields, the reconciled live
# state line, the decision text + options when the task is awaiting a decision,
# and a short recent-status tail. Every line is width-clipped and the card is
# bounded to <= $rows lines. Deterministic given its args.
fm_dock_render_detail() {  # <detail_json> <width> <rows> <color>
  local djson=$1 width=$2 rows=$3 color=$4
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  [ "$width" -ge 20 ] || width=20
  case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
  [ "$rows" -ge 6 ] || rows=6
  printf '%s' "$djson" | jq -r \
    --argjson width "$width" --argjson rows "$rows" --argjson color "$color" \
    "$FM_DOCK_JQ_PRELUDE"'
    def val($v): ($v | if . == "" or . == null then "-" else . end);
    ([ paint("1;36"; "Task " + (.id // "-")) + "   " + esc("2") + "esc back · q quit" + reset, "",
      "  project   " + val(.project),
      "  harness   " + val(.harness),
      "  mode      " + val(.mode),
      "  kind      " + val(.kind),
      "  branch    " + val(.branch),
      "  state     " + paint(pcol(.phase // "-"); (.phase // "-"))
        + " " + esc("2") + "·" + reset + " " + (.owner // "-")
        + " " + esc("2") + "·" + reset + " " + paint(hcol(.health // "-"); (.health // "-"))
        + " " + esc("2") + "· " + (.age // "-") + reset,
      (if (.crew_state // "") == "" then empty else "  live      " + esc("2") + (.crew_state) + reset end),
      (if .pr_url == null then empty else "  pr        " + .pr_url end),
      "" ]
    + (if (.decision.present // false)
       then [ paint("33;1"; "  DECISION NEEDED"), "  " + (.decision.text // "-"), "" ]
       else [] end)
    + [ paint("2"; "  recent status:") ]
    + (if ((.status_tail // []) | length) == 0 then [ "    " + esc("2") + "(none)" + reset ]
       else [ .status_tail[] | "    " + esc("2") + (.) + reset ] end)
    + [ "", paint("2"; "  a answer n note m merge p peek i intr t tear · esc back · q quit") ])
    | .[0:$rows] | map(fit(.)) | join("\n")
    '
}
