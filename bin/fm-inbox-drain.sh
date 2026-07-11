#!/usr/bin/env bash
# fm-inbox-drain.sh - firstmate's read/execute/resolve interface to the captain
# command inbox (bin/fm-inbox-lib.sh owns the intent schema and state machine).
#
# This is the firstmate-mediated executor's front door, the analogue of
# bin/fm-wake-drain.sh for captain commands. The Dock console only ever WRITES
# intents; firstmate is the sole executor.
#
# Default run (no args): print one compact JSON record per pending intent,
# oldest-first, claiming each with a compare-and-swap so two concurrent drains
# can never double-surface the same intent. An `answer` whose recorded
# decision_id no longer matches the task's current decision token is auto-rejected
# here (never surfaced). It also RE-SURFACES a claim stranded past
# FM_INBOX_RECLAIM_SECS (default 900) by a crash between claim and resolve, so a
# captain command can never be silently lost.
#
#   --execute <intent_id>   execute a CLAIMED intent via the EXISTING helper and
#                           resolve it. answer/note dispatch to bin/fm-send.sh
#                           (answer REVALIDATES the decision token immediately
#                           before the send and rejects rather than mis-applies if
#                           the gate moved); peek reads bin/fm-crew-state.sh. The
#                           destructive/irreversible actions merge, teardown, and
#                           interrupt (and promote/archive) are NOT auto-executed:
#                           they stay claimed for firstmate to confirm with the
#                           captain and resolve, exactly as any such request does
#                           today. The inbox only carries the request.
#   --resolve <id> <status> [result...]   record an outcome (done|rejected|error).
#   --show <intent_id>      print one intent's JSON, live or resolved (read-only).
#   --list                  list pending intents and note any unparseable file (read-only).
#   -h, --help              this help.
#
# PROVENANCE: an intent carries no cryptographic authorship - any local process
# that can write state/captain-inbox/ (including a crewmate, which already writes
# its own status file there) can forge one. merge/teardown/interrupt stay behind
# the captain's confirmation, but an `answer` approves a decision gate in the
# captain's voice, so firstmate should treat a surfaced answer with the same
# judgment it applies to any decision relay and be wary of one whose content a
# crewmate would benefit from. The console stamps version="fm-dock".
#
# Each default-run/execute-surface line is compact JSON: {intent_id, task_id,
# action, payload, decision_id, version, ts}. jq is required.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-inbox-lib.sh
. "$SCRIPT_DIR/fm-inbox-lib.sh"

# How long a claim may sit unresolved before the drain re-surfaces it as a
# probable crash-stranded command.
FM_INBOX_RECLAIM_SECS="${FM_INBOX_RECLAIM_SECS:-900}"
# Execution seams so tests can inject recorders; default to the real helpers.
FM_INBOX_SEND_BIN="${FM_INBOX_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
FM_INBOX_CREW_STATE_BIN="${FM_INBOX_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: fm-inbox-drain.sh requires jq" >&2; exit 1; }
}

# One actionable record for firstmate: the fields it needs to dispatch to the
# right existing helper, plus provenance. Compact JSON so an arbitrary payload is
# unambiguous.
emit_record() {  # <file>
  jq -c '{intent_id, task_id, action, payload, decision_id, version, ts}' "$1"
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
  file=$(fm_inbox_locate "$id") || { echo "error: no such intent: $id" >&2; exit 1; }
  jq . "$file"
}

cmd_list() {
  require_jq
  local ts id file action f status
  while IFS="$FM_INBOX_TAB" read -r ts id file; do
    [ -n "$file" ] || continue
    action=$(fm_inbox_field "$file" action)
    printf '%s\t%s\t%s\n' "$id" "$action" "$ts"
  done < <(fm_inbox_list_pending)
  # Note any unparseable/invalid file so a corrupted command is not silent.
  for f in "$FM_INBOX_DIR"/*.json; do
    [ -e "$f" ] || continue
    status=$(fm_inbox_validate_and_status "$f") || { echo "INBOX: unparseable/invalid intent file: $f" >&2; continue; }
    [ "$status" = claimed ] && echo "INBOX: intent $(basename "$f" .json) is claimed (in progress or stranded)" >&2
  done
}

# Default drain: surface + CAS-claim each pending intent (auto-rejecting a stale
# answer), then re-surface any claim stranded past FM_INBOX_RECLAIM_SECS.
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
          fm_inbox_resolve "$id" rejected \
            "stale answer: recorded decision token '$decision_id' no longer matches current '$current'" \
            || true
          continue
        fi
      fi
    fi
    # CAS claim: emit only if THIS drain won the pending->claimed transition, so
    # a concurrent drain cannot also emit the same intent.
    fm_inbox_claim_file "$file" || continue
    emit_record "$file"
  done < <(fm_inbox_list_pending)

  # Recover crash-stranded claims: a claim older than the reclaim window was
  # surfaced but never resolved (firstmate died/errored between claim and
  # resolve). CAS-reclaim it (refresh claim_ts) and re-surface; the CAS means two
  # concurrent drains re-surface a given stranded claim at most once.
  while IFS="$FM_INBOX_TAB" read -r ts id file; do
    [ -n "$file" ] || continue
    fm_inbox_reclaim_stale "$file" "$FM_INBOX_RECLAIM_SECS" || continue
    emit_record "$file"
  done < <(fm_inbox_list_claimed_stale "$FM_INBOX_RECLAIM_SECS")
}

# Execute a CLAIMED intent via the existing helper and resolve it. Only the
# standing-authorized reversible actions run here; the destructive ones refuse.
cmd_execute() {
  require_jq
  local id=${1:-} file action task payload decision_id current out
  [ -n "$id" ] || { echo "usage: fm-inbox-drain.sh --execute <intent_id>" >&2; exit 2; }
  file="$FM_INBOX_DIR/$id.json"
  [ -f "$file" ] || { echo "error: no such live intent: $id" >&2; exit 1; }
  [ "$(fm_inbox_field "$file" status)" = claimed ] \
    || { echo "error: intent $id is not claimed; drain it first" >&2; exit 1; }
  action=$(fm_inbox_field "$file" action)
  task=$(fm_inbox_field "$file" task_id)
  payload=$(fm_inbox_field "$file" payload)
  case "$action" in
    answer)
      # Revalidate the decision token IMMEDIATELY before the send: the gate may
      # have moved between claim and now. Reject rather than mis-apply.
      decision_id=$(fm_inbox_field "$file" decision_id)
      current=$(fm_inbox_decision_token "$task")
      if [ -z "$decision_id" ] || [ "$decision_id" != "$current" ]; then
        fm_inbox_resolve "$id" rejected "stale at execution: token '$decision_id' != current '$current'" || true
        echo "rejected: the decision gate moved before the answer could be sent" >&2
        return 3
      fi
      if "$FM_INBOX_SEND_BIN" "$task" "$payload"; then
        fm_inbox_resolve "$id" "done" "answer sent to $task"
      else
        fm_inbox_resolve "$id" error "fm-send failed sending answer to $task" || true
        return 1
      fi
      ;;
    note)
      if "$FM_INBOX_SEND_BIN" "$task" "$payload"; then
        fm_inbox_resolve "$id" "done" "note sent to $task"
      else
        fm_inbox_resolve "$id" error "fm-send failed sending note to $task" || true
        return 1
      fi
      ;;
    peek)
      out=$("$FM_INBOX_CREW_STATE_BIN" "$task" 2>&1) || true
      printf '%s\n' "$out"
      fm_inbox_resolve "$id" "done" "peeked $task"
      ;;
    merge|teardown|interrupt|promote|archive)
      echo "action '$action' is destructive/irreversible or firstmate-handled; not auto-executed." >&2
      echo "It stays claimed for firstmate to confirm with the captain and resolve." >&2
      return 2
      ;;
    *)
      echo "error: unknown action: $action" >&2
      return 2
      ;;
  esac
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --resolve) shift; cmd_resolve "$@" ;;
  --execute) shift; cmd_execute "$@" ;;
  --show) shift; cmd_show "$@" ;;
  --list) shift; cmd_list "$@" ;;
  '') cmd_drain ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
