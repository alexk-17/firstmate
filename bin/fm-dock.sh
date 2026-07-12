#!/usr/bin/env bash
# fm-dock.sh - the Fleet Dock CONTROL surface: an interactive terminal console
# that lets the captain submit an action against a task (answer a decision, send
# a note, request a merge, peek, interrupt, tear down) without leaving the
# terminal. It is the write-side companion to the read-only bin/fm-fleet-status.sh.
#
# It does exactly two things: it RENDERS live fleet state read-only (by reusing
# bin/fm-fleet-status.sh - it never re-derives state), and it WRITES a captain
# intent into the durable command inbox (bin/fm-inbox-lib.sh). It performs NO
# backend action: crewmates, PRs, and worktrees are only ever touched by
# firstmate, which reads the inbox via bin/fm-inbox-drain.sh and executes each
# intent with the existing helper, applying the usual authority gates. The Dock
# only carries the request. This preserves the single accountable agent.
#
# Interactive surface: on a capable interactive tty the DEFAULT is a full-screen
# live TUI (cmd_tui) - a k9s-style dashboard the captain leaves open to watch the
# fleet and act with single keystrokes. It is layered strictly ON TOP: it only
# RENDERS read-only state and WRITES intents through the SAME validated
# write_intent path; it performs no backend action and changes no other command's
# behavior. When stdout/stdin is not a tty, or NO_COLOR/TERM=dumb, it falls back
# to the original keyboard-driven picker loop (cmd_interactive_picker), kept
# intact: reliable, plain-text under NO_COLOR, trivially scriptable for tests and
# demos, and never hangs (it exits at stdin EOF; every flag parse rejects a
# missing value instead of looping). --tui / --plain force either surface.
#
# The TUI itself splits into a PURE, tested render/selection/dispatch core
# (bin/fm-dock-tui-lib.sh, exercised by tests/fm-dock-tui.test.sh) and a thin,
# deliberately-untested raw-mode input+refresh loop here. The loop saves the tty
# state and enters the alternate screen on entry and an EXIT/INT/TERM trap always
# restores them, so the terminal is never left wedged on any exit path; WINCH
# re-renders to the new size; the loop blocks on a single keypress with a timeout
# so a key is instant and the screen auto-refreshes on timeout (never busy-spins).
#
# Validation before a write (also re-checked by the drain, since files can arrive
# without the console): the task must exist (a live meta), the action must be in
# the allowlist, answer/note require a non-empty single-line payload within a size
# bound, no-payload actions reject a payload, and an `answer` requires the target
# to be awaiting a decision so a live decision token can be stamped for staleness
# rejection.
#
# Usage:
#   fm-dock.sh                          interactive dashboard: full-screen TUI on a
#                                       capable tty, else the picker loop.
#   fm-dock.sh --tui                    force the full-screen TUI (needs a tty).
#   fm-dock.sh --plain                  force the plain picker loop.
#   fm-dock.sh status                   render the fleet digest once, then exit.
#   fm-dock.sh submit --task <id> --action <action> [--payload <text>]
#             [--intent-id <id>]        headless one-shot: write a single intent
#                                       and print its id. No TTY needed.
#   fm-dock.sh -h | --help
#
#   action is one of: answer note merge peek interrupt teardown promote archive.
#
# Env:
#   FM_DOCK_REFRESH=<secs>   TUI auto-refresh interval (default 3, min 1).
#   NO_COLOR / non-tty       disable color and the TUI (falls back to the picker).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-inbox-lib.sh
. "$SCRIPT_DIR/fm-inbox-lib.sh"
# shellcheck source=bin/fm-dock-tui-lib.sh
. "$SCRIPT_DIR/fm-dock-tui-lib.sh"
STATUS_BIN="$SCRIPT_DIR/fm-fleet-status.sh"
DOCK_VERSION="fm-dock"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: fm-dock.sh requires jq" >&2; exit 1; }
}

# Color only for an interactive, color-allowed terminal; otherwise plain. The
# NO_COLOR spec disables color whenever the variable is PRESENT, even when empty,
# so test presence with ${NO_COLOR+x}, never value-emptiness.
COLOR=false
if [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != dumb ] && [ -t 1 ]; then
  COLOR=true
fi
paint() {  # <ansi-code> <text>
  if [ "$COLOR" = true ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

render_digest() {
  if [ -x "$STATUS_BIN" ]; then
    "$STATUS_BIN" || echo "(fleet digest unavailable)"
  else
    echo "(fm-fleet-status.sh not found)"
  fi
}

# The in-flight task ids the captain can act on, from the same projection the
# digest is built from (never re-derived here).
inflight_ids() {
  command -v jq >/dev/null 2>&1 || return 0
  "$STATUS_BIN" --json 2>/dev/null \
    | jq -r '[.sections.needs_you[]?, .sections.at_risk[]?, .sections.running[]?] | .[].id' 2>/dev/null
}

# Validate a submission and echo an error to stderr on the first failure (return
# non-zero). Actions requiring a payload: answer, note. Others take none.
validate_submission() {  # <task> <action> <payload>
  local task=$1 action=$2 payload=$3
  if ! fm_inbox_valid_action "$action"; then
    echo "error: unknown action '$action'" >&2; return 2
  fi
  if ! fm_inbox_valid_id "$task"; then
    echo "error: task id '$task' is not a valid task id" >&2; return 2
  fi
  if ! fm_inbox_task_exists "$task"; then
    echo "error: task '$task' is not a live task in this home (no meta - torn down or never existed)" >&2; return 2
  fi
  case "$action" in
    answer|note)
      [ -n "$payload" ] || { echo "error: action '$action' requires a payload" >&2; return 2; }
      case "$payload" in *$'\n'*) echo "error: payload must be a single line (fm-send sends one literal line)" >&2; return 2 ;; esac
      [ "${#payload}" -le "$FM_INBOX_MAX_PAYLOAD" ] || { echo "error: payload exceeds $FM_INBOX_MAX_PAYLOAD bytes" >&2; return 2; }
      ;;
    *)
      [ -z "$payload" ] || { echo "error: action '$action' takes no payload" >&2; return 2; }
      ;;
  esac
  if [ "$action" = answer ]; then
    fm_inbox_task_awaiting_decision "$task" \
      || { echo "error: task '$task' is not awaiting a decision; nothing to answer" >&2; return 2; }
  fi
  return 0
}

# Write one validated intent, auto-stamping the decision token for answers and
# the console provenance marker. Echoes the id.
write_intent() {  # <task> <action> <payload> <intent_id>
  local task=$1 action=$2 payload=$3 id=$4 decision_id=""
  validate_submission "$task" "$action" "$payload" || return $?
  [ -n "$id" ] || id=$(fm_inbox_new_id)
  fm_inbox_valid_id "$id" || { echo "error: invalid --intent-id '$id'" >&2; return 2; }
  if [ "$action" = answer ]; then
    decision_id=$(fm_inbox_decision_token "$task")
    [ -n "$decision_id" ] || { echo "error: task '$task' has no decision token to guard the answer" >&2; return 2; }
  fi
  fm_inbox_write "$id" "$task" "$action" "$payload" "$decision_id" "$DOCK_VERSION"
}

cmd_submit() {
  require_jq
  local task="" action="" payload="" intent_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || { echo "error: --task requires a value" >&2; return 2; }; task=$2; shift 2 ;;
      --action) [ $# -ge 2 ] || { echo "error: --action requires a value" >&2; return 2; }; action=$2; shift 2 ;;
      --payload) [ $# -ge 2 ] || { echo "error: --payload requires a value" >&2; return 2; }; payload=$2; shift 2 ;;
      --intent-id) [ $# -ge 2 ] || { echo "error: --intent-id requires a value" >&2; return 2; }; intent_id=$2; shift 2 ;;
      *) echo "error: unknown submit argument: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$task" ] && [ -n "$action" ] || { echo "usage: fm-dock.sh submit --task <id> --action <action> [--payload <text>]" >&2; return 2; }
  local out
  out=$(write_intent "$task" "$action" "$payload" "$intent_id") || return $?
  printf 'queued intent %s (%s for %s)\n' "$out" "$action" "$task"
}

# Plain picker loop (the non-tty / NO_COLOR fallback, and --plain). Reads plain
# lines from stdin so it is scriptable and never hangs: an EOF on any prompt ends
# the loop cleanly. Unchanged from the original interactive console.
cmd_interactive_picker() {
  require_jq
  local ids task action payload confirm id
  while :; do
    printf '\n'
    render_digest
    ids=$(inflight_ids)
    printf '\n%s\n' "$(paint '1;36' 'Fleet Dock - submit a captain command')"
    if [ -n "$ids" ]; then
      printf '%s\n' "$(paint 2 'in-flight tasks:')"
      printf '%s\n' "$ids" | sed 's/^/  /'
    fi
    printf '%s' "$(paint '1' 'task id (blank or q to quit): ')"
    IFS= read -r task || break
    case "$task" in ''|q|quit|Q) break ;; esac

    printf '%s' "$(paint '1' 'action [answer|note|merge|peek|interrupt|teardown]: ')"
    IFS= read -r action || break
    if ! fm_inbox_valid_action "$action"; then
      printf '%s\n' "$(paint 33 "unknown action '$action' - try again")"
      continue
    fi

    payload=""
    case "$action" in
      answer|note)
        printf '%s' "$(paint '1' 'payload text: ')"
        IFS= read -r payload || break
        ;;
    esac

    case "$action" in
      merge|teardown|interrupt)
        printf '%s\n' "$(paint 33 "note: $action is destructive/disruptive - firstmate still asks the captain to confirm before acting")"
        ;;
    esac

    printf '%s' "$(paint '1' "submit '$action' for '$task'? [y/N]: ")"
    IFS= read -r confirm || break
    case "$confirm" in
      y|Y|yes|YES)
        if id=$(write_intent "$task" "$action" "$payload" ""); then
          printf '%s\n' "$(paint 32 "queued intent $id - firstmate will act on it")"
        else
          printf '%s\n' "$(paint 31 'not queued (see the error above)')"
        fi
        ;;
      *) printf '%s\n' "$(paint 2 'cancelled')" ;;
    esac
  done
}

# --- full-screen TUI (impure I/O layer over bin/fm-dock-tui-lib.sh) ---------
#
# Everything the captain SEES is produced by the pure renderers in the lib; this
# layer only gathers inputs (read-only), draws the returned string, reads one
# keypress with a timeout, and dispatches through the SAME write_intent path.

# A real interactive terminal on both ends, with the tput we need to drive it.
tui_has_tty() { [ -t 0 ] && [ -t 1 ] && command -v tput >/dev/null 2>&1; }
# Auto-select the TUI only when it will also be legible (color-capable terminal).
# NO_COLOR present (even empty) means fall back to the picker: test with
# ${NO_COLOR+x}, not value-emptiness, so NO_COLOR= is honored.
tui_auto() { tui_has_tty && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR+x}" ]; }

# Read one static config value from a task's live meta (not fleet STATE; the
# renderer's fleet state still comes only from fm-fleet-status.sh).
meta_get() {  # <id> <key>
  local line
  line=$(grep -E "^$2=" "$STATE/$1.meta" 2>/dev/null | head -1) || true
  printf '%s' "${line#*=}"
}

# Compact JSON array of the captain's own most-recent intents and their status,
# newest first and bounded, read from the inbox (live + resolved). Read-only.
collect_inbox() {
  local f
  { for f in "$FM_INBOX_DIR"/*.json "$FM_INBOX_DONE_DIR"/*.json; do
      [ -e "$f" ] || continue
      jq -c '{intent_id, task_id, action, status, ts}' "$f" 2>/dev/null
    done; } | jq -s 'sort_by(.ts) | reverse | .[0:6]' 2>/dev/null || printf '[]'
}

# Assemble the detail object for one task: its fleet-status row (authoritative
# phase/owner/health/age) plus static config from meta, the reconciled live-state
# line, the decision text when awaiting one, and a short recent-status tail.
build_detail() {  # <id> <status_json>
  local id=$1 sjson=$2 row harness mode project worktree branch csline
  local dec_present=false dec_text="" tail_json
  # A recently-done task has no live meta (torn down); build its detail from the
  # RECENTLY DONE digest entry - title, repo, and the artifact (PR url, report
  # path, or merge note), which is the whole point of viewing it.
  local drow
  drow=$(printf '%s' "$sjson" | jq -c --arg id "$id" \
    '(.sections.recently_done // []) | map(select(.id == $id)) | (.[0] // empty)' 2>/dev/null) || drow=""
  if [ -n "$drow" ]; then
    printf '%s' "$drow" | jq --arg id "$id" '{
      id: $id, project: (.repo // "-"), harness: "-", mode: "-", kind: "done",
      phase: "done", owner: "-", health: "-", age: "-",
      pr_url: (if ((.artifact // "") | test("^https?://")) then .artifact else null end),
      branch: "-", crew_state: "",
      decision: {present: false, text: ""},
      status_tail: ([ (.title // empty) ]
        + (if ((.artifact // "") != "") and (((.artifact // "") | test("^https?://")) | not)
           then [ .artifact ] else [] end))
    }' 2>/dev/null || printf '{"id":"%s","phase":"done"}' "$id"
    return 0
  fi
  row=$(printf '%s' "$sjson" | jq -c --arg id "$id" \
    '[.sections.needs_you[]?, .sections.at_risk[]?, .sections.running[]?]
     | map(select(.id == $id)) | (.[0] // {})' 2>/dev/null) || row='{}'
  harness=$(meta_get "$id" harness)
  mode=$(meta_get "$id" mode)
  project=$(meta_get "$id" project)
  worktree=$(meta_get "$id" worktree)
  branch="-"
  if [ -n "$worktree" ] && command -v git >/dev/null 2>&1; then
    branch=$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null) || branch=""
    [ -n "$branch" ] || branch="-"
  fi
  csline=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || csline=""
  if fm_inbox_task_awaiting_decision "$id"; then
    dec_present=true
    dec_text=$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -1) || dec_text=""
  fi
  tail_json=$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -6 \
    | jq -R . | jq -s . 2>/dev/null) || tail_json='[]'
  [ -n "$tail_json" ] || tail_json='[]'
  printf '%s' "$row" | jq \
    --arg id "$id" --arg harness "$harness" --arg mode "$mode" --arg project "$project" \
    --arg branch "$branch" --arg csline "$csline" \
    --argjson dec_present "$dec_present" --arg dec_text "$dec_text" \
    --argjson tail "$tail_json" '{
      id: $id, project: $project, harness: $harness, mode: $mode,
      kind: (.kind // "-"), phase: (.phase // "-"), owner: (.owner // "-"),
      health: (.health // "-"), age: (.freshness.age // "-"), pr_url: .pr_url,
      branch: $branch, crew_state: $csline,
      decision: {present: $dec_present, text: $dec_text}, status_tail: $tail
    }' 2>/dev/null || printf '{"id":"%s"}' "$id"
}

TUI_SAVED_STTY=""
tui_teardown() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  [ -n "$TUI_SAVED_STTY" ] && stty "$TUI_SAVED_STTY" 2>/dev/null || true
}

# Bottom-line single-key confirm; returns 0 only on y/Y. All terminal control and
# the keypress go through /dev/tty (the controlling terminal), NEVER stdout/stdin,
# so a caller in command substitution cannot capture any of it.
tui_confirm() {  # <prompt>
  local ans rows
  rows=$(tput lines 2>/dev/null) || rows=24
  { tput cnorm; tput cup "$((rows - 1))" 0; printf '\033[2K%s' "$1"; } >/dev/tty 2>/dev/null || true
  IFS= read -rsn1 ans </dev/tty || { tput civis >/dev/tty 2>/dev/null || true; return 1; }
  tput civis >/dev/tty 2>/dev/null || true
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# Bottom-line single-line payload prompt. The prompt bytes, cursor moves, and the
# echoed keystrokes ALL go to /dev/tty; only the entered line is written to
# stdout. This is the fix for the payload-contamination bug: tui_action captures
# this in $(...), so anything but the bare line would end up inside the intent.
tui_prompt() {  # <prompt>  -> stdout: the entered line only
  local line rows
  rows=$(tput lines 2>/dev/null) || rows=24
  { tput cnorm; tput cup "$((rows - 1))" 0; printf '\033[2K%s' "$1"; } >/dev/tty 2>/dev/null || true
  # The session runs in -icanon -echo (cmd_tui); restore cooked+echo just for this
  # line entry so the captain sees and can edit what they type, then return to the
  # char-at-a-time mode the key loop needs. stty writes to /dev/tty only, so the
  # captured stdout stays exactly the entered line (payload-contamination fix).
  stty icanon echo </dev/tty 2>/dev/null || true
  IFS= read -r line </dev/tty || line=""
  stty -icanon -echo min 1 time 0 </dev/tty 2>/dev/null || true
  tput civis >/dev/tty 2>/dev/null || true
  printf '%s' "$line"
}

# Compose one action against <id> through the EXISTING validated write path,
# prompting for a payload and confirming destructive actions first. Sets TUI_FLASH
# to the queued/rejected/cancelled result for the next render.
tui_action() {  # <key> <id>
  local action=$1 id=$2 payload="" out
  action=$(fm_dock_action_for_key "$action")
  [ -n "$action" ] || return 0
  [ -n "$id" ] || { TUI_FLASH="no task selected"; return 0; }
  if fm_dock_action_needs_payload "$action"; then
    payload=$(tui_prompt "$action for $id: ")
    [ -n "$payload" ] || { TUI_FLASH="cancelled ($action needs text)"; return 0; }
  fi
  if fm_dock_action_is_destructive "$action"; then
    tui_confirm "queue '$action' for $id? firstmate still confirms before acting [y/N] " \
      || { TUI_FLASH="cancelled"; return 0; }
  fi
  if out=$(write_intent "$id" "$action" "$payload" "" 2>&1); then
    TUI_FLASH="queued: $action $id"
  else
    TUI_FLASH="rejected: $(printf '%s' "$out" | head -1 | sed 's/^error: //')"
  fi
}

cmd_tui() {
  require_jq
  local refresh=${FM_DOCK_REFRESH:-3}
  case "$refresh" in ''|*[!0-9]*) refresh=3 ;; esac
  [ "$refresh" -ge 1 ] || refresh=3

  TUI_SAVED_STTY=$(stty -g 2>/dev/null) || TUI_SAVED_STTY=""
  # Restore the terminal on every exit path, and make a signal-driven exit
  # DISTINGUISHABLE from a normal quit: INT->130, TERM->143 (a supervisor can tell
  # the captain terminated the dock from a clean `q`). The EXIT trap re-runs
  # teardown, which is idempotent.
  trap 'tui_teardown; exit 130' INT
  trap 'tui_teardown; exit 143' TERM
  trap 'tui_teardown' EXIT
  # bash 3.2's timed `read` is NOT reliably interrupted by SIGWINCH, so a resize
  # is picked up on the next refresh tick (within $refresh seconds) rather than
  # instantly. The trap is harmless and does interrupt read on bash >=4.
  trap ':' WINCH
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  # Put the terminal in char-at-a-time, no-echo mode for the whole TUI session.
  # Relying on per-read `-s`/`-n` alone left echo-and-line-buffer gaps (notably
  # across the auto-refresh window) where arrow-key bytes leaked to the screen as
  # literal input instead of moving the selection. tui_teardown restores the
  # saved stty on every exit path; tui_prompt restores cooked mode for line entry.
  stty -icanon -echo min 1 time 0 </dev/tty 2>/dev/null || true

  local view=list sel=0 sel_id="" status_json inbox_json cols rowsn stamp count screen
  local key rest rc before
  TUI_FLASH=""
  while :; do
    status_json=$("$STATUS_BIN" --json 2>/dev/null) || status_json='{}'
    inbox_json=$(collect_inbox)
    cols=$(tput cols 2>/dev/null) || cols=80
    rowsn=$(tput lines 2>/dev/null) || rowsn=24
    stamp=$(date +%H:%M:%S)
    count=$(fm_dock_selectable_count "$status_json")
    sel=$(fm_dock_clamp_sel "$sel" "$count")
    sel_id=$(fm_dock_nth_id "$status_json" "$sel")

    if [ "$view" = detail ] && [ -n "$sel_id" ]; then
      screen=$(fm_dock_render_detail "$(build_detail "$sel_id" "$status_json")" "$cols" "$rowsn" "$COLOR")
    else
      view=list
      screen=$(fm_dock_render_list "$status_json" "$sel" "$cols" "$rowsn" "$COLOR" "$stamp" "$refresh" "$inbox_json" "$TUI_FLASH")
    fi
    printf '\033[2J\033[H%s' "$screen"
    TUI_FLASH=""   # a flash shows for exactly one refresh cycle

    # One keypress, or an auto-refresh tick. read's status is captured DIRECTLY
    # (never behind `if !`, whose negation would clobber $?). On a non-zero read,
    # distinguish a genuine terminal EOF (Ctrl-D / closed stdin -> exit) from a
    # refresh timeout (-> re-render):
    #   bash >=4: a timeout returns >128 and EOF returns 1, so rc==1 IS EOF.
    #   bash 3.2: BOTH return 1, so also require zero elapsed wall time - a real
    #     >=1s timeout always advances SECONDS by >=1 (a >=1s span crosses a
    #     second boundary), while EOF returns instantly. SIGWINCH does not
    #     interrupt bash 3.2's timed read, so a zero-elapsed rc==1 is truly EOF.
    key=""
    before=$SECONDS
    IFS= read -rsn1 -t "$refresh" key
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 1 ] && [ "$((SECONDS - before))" -eq 0 ]; then
        break   # terminal EOF (Ctrl-D / closed input) -> clean exit
      fi
      continue  # timeout (or a bash>=4 signal-interrupted read) -> re-render
    fi
    # Decode an arrow-key escape sequence (ESC [ A/B/C/D). Integer -t only: bash
    # 3.2 rejects a fractional timeout. The two continuation bytes arrive with the
    # ESC so this returns instantly; a lone ESC waits out the 1s, then registers.
    if [ "$key" = $'\033' ]; then
      rest=""
      IFS= read -rsn2 -t 1 rest
      # CSI (ESC [ A) and SS3 (ESC O A, "application cursor keys" mode) both occur.
      case "$rest" in
        '[A'|'OA') key=up ;;   '[B'|'OB') key=down ;;
        '[C'|'OC') key=right ;; '[D'|'OD') key=left ;;
        *) key=esc ;;
      esac
    fi
    # Ctrl-D quits whether the terminal delivers it as EOF (handled above) or, in
    # a non-canonical read, as a literal 0x04 byte.
    [ "$key" = $'\004' ] && break

    if [ "$view" = detail ]; then
      case "$key" in
        q|Q) break ;;
        esc|left) view=list ;;
        a|n|m|p|i|t)
          if fm_dock_id_is_actionable "$status_json" "$sel_id"; then tui_action "$key" "$sel_id"
          else TUI_FLASH="$key: not available for a completed task"; fi ;;
      esac
    else
      case "$key" in
        q|Q) break ;;
        up|k) sel=$(fm_dock_move_sel "$sel" "$count" up) ;;
        down|j) sel=$(fm_dock_move_sel "$sel" "$count" down) ;;
        ''|right) [ "$count" -gt 0 ] && view=detail ;;   # Enter opens the detail view
        a|n|m|p|i|t)
          if fm_dock_id_is_actionable "$status_json" "$sel_id"; then tui_action "$key" "$sel_id"
          else TUI_FLASH="$key: not available for a completed task"; fi ;;
      esac
    fi
  done
}

# Choose the interactive surface: forced --tui/--plain, else auto-detect. Falls
# back to the picker whenever the TUI cannot run, so it never hangs.
cmd_interactive_default() {  # [force]
  case "${1:-}" in
    plain) cmd_interactive_picker ;;
    tui)
      if tui_has_tty; then cmd_tui
      else echo "fm-dock: no interactive tty for --tui; using the plain picker" >&2; cmd_interactive_picker; fi
      ;;
    *)
      if tui_auto; then cmd_tui; else cmd_interactive_picker; fi
      ;;
  esac
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status) render_digest ;;
  submit) shift; cmd_submit "$@" ;;
  --tui) cmd_interactive_default tui ;;
  --plain) cmd_interactive_default plain ;;
  '') cmd_interactive_default ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
