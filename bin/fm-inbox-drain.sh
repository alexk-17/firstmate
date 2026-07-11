#!/usr/bin/env bash
# fm-inbox-drain.sh - firstmate's read/execute/resolve interface to the captain
# command inbox (bin/fm-inbox-lib.sh owns the intent schema).
#
# This is the firstmate-mediated executor's front door, the analogue of
# bin/fm-wake-drain.sh for captain commands. The Dock console only ever WRITES
# intents; firstmate is the sole executor. This script never touches crewmates,
# PRs, or worktrees itself - it surfaces each pending intent as one actionable
# record for firstmate to carry out with the EXISTING helper for that action:
#   answer     -> bin/fm-send.sh (or the no-mistakes respond flow for a gate)
#   note       -> bin/fm-send.sh (one-line steer)
#   merge      -> bin/fm-pr-merge.sh
#   peek       -> bin/fm-crew-state.sh / bin/fm-peek.sh
#   interrupt  -> the harness interrupt (harness-adapters)
#   teardown   -> bin/fm-teardown.sh
# then resolve the intent with --resolve.
#
# AUTHORITY (hard rule): merge, teardown, and interrupt are destructive,
# irreversible, or disruptive. The inbox does NOT auto-execute them - it only
# carries the request, exactly as a captain-typed request would arrive today.
# Firstmate surfaces them for the captain's confirmation per AGENTS.md before
# acting (yolo relaxes only the routine, non-destructive approvals). This script
# deliberately performs no backend action; keeping execution in firstmate's hands
# preserves the single accountable agent and every authority gate.
#
# Default run (no args): print one compact JSON record per pending intent,
# oldest-first, and mark each `claimed` so it is not surfaced twice. An `answer`
# whose recorded decision_id no longer matches the task's current decision token
# (the gate moved on) is auto-rejected here - never surfaced, never mis-applied.
#
#   --resolve <intent_id> <status> [result...]   record the outcome after acting.
#                                                status: done | rejected | error
#   --show <intent_id>                           print one intent's JSON (read-only).
#   --list                                       list pending intents (ts, id, action)
#                                                without claiming (read-only).
#   -h, --help                                   this help.
#
# Each default-run line is compact JSON: {intent_id, task_id, action, payload,
# decision_id, ts}. jq is required (the whole inbox is jq-backed).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-inbox-lib.sh
. "$SCRIPT_DIR/fm-inbox-lib.sh"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: fm-inbox-drain.sh requires jq" >&2; exit 1; }
}

# One actionable record for firstmate: the fields it needs to dispatch to the
# right existing helper. Compact JSON so an arbitrary payload (decision text with
# quotes/spaces) is unambiguous.
emit_record() {  # <file>
  jq -c '{intent_id, task_id, action, payload, decision_id, ts}' "$1"
}

cmd_resolve() {
  require_jq
  local id=${1:-} status=${2:-} result
  [ -n "$id" ] && [ -n "$status" ] || { echo "usage: fm-inbox-drain.sh --resolve <intent_id> <status> [result...]" >&2; exit 2; }
  shift 2 || true
  result="$*"
  fm_inbox_resolve "$id" "$status" "$result"
}

cmd_show() {
  require_jq
  local id=${1:-} file
  [ -n "$id" ] || { echo "usage: fm-inbox-drain.sh --show <intent_id>" >&2; exit 2; }
  file=$(fm_inbox_path "$id")
  [ -f "$file" ] || { echo "error: no such intent: $id" >&2; exit 1; }
  jq . "$file"
}

cmd_list() {
  require_jq
  local ts id file action
  while IFS="$FM_INBOX_TAB" read -r ts id file; do
    [ -n "$file" ] || continue
    action=$(fm_inbox_field "$file" action)
    printf '%s\t%s\t%s\n' "$id" "$action" "$ts"
  done < <(fm_inbox_list_pending)
}

# Default drain: surface + claim each pending intent, auto-rejecting a stale answer.
cmd_drain() {
  require_jq
  local ts id file action decision_id current
  while IFS="$FM_INBOX_TAB" read -r ts id file; do
    [ -n "$file" ] || continue
    action=$(fm_inbox_field "$file" action)
    if [ "$action" = answer ]; then
      decision_id=$(fm_inbox_field "$file" decision_id)
      if [ -n "$decision_id" ]; then
        current=$(fm_inbox_decision_token "$(fm_inbox_field "$file" task_id)")
        if [ "$decision_id" != "$current" ]; then
          # The gate this answer targeted has moved on - reject deterministically
          # instead of surfacing it for a mis-apply against a different decision.
          fm_inbox_resolve "$id" rejected \
            "stale answer: recorded decision token '$decision_id' no longer matches current '$current'" \
            || true
          continue
        fi
      fi
    fi
    fm_inbox_claim "$id" || continue
    emit_record "$file"
  done < <(fm_inbox_list_pending)
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --resolve) shift; cmd_resolve "$@" ;;
  --show) shift; cmd_show "$@" ;;
  --list) shift; cmd_list "$@" ;;
  '') cmd_drain ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
