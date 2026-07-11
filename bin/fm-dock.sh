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
# TUI choice: a keyboard-driven picker LOOP, not a full-screen curses TUI. A
# curses UI in pure bash is fragile across terminals; a prompt loop is reliable,
# degrades cleanly to plain text under NO_COLOR or a non-tty, is trivially
# scriptable for tests and demos, and never hangs (it exits at stdin EOF). The
# live digest is re-rendered each loop, which is the "pane" the captain reads.
#
# Usage:
#   fm-dock.sh                          interactive control loop (render + submit).
#   fm-dock.sh status                   render the fleet digest once, then exit.
#   fm-dock.sh submit --task <id> --action <action> [--payload <text>]
#             [--intent-id <id>] [--decision-id <token> | --no-decision]
#                                       headless one-shot: write a single intent
#                                       and print its id. No TTY needed.
#   fm-dock.sh -h | --help
#
#   action is one of: answer note merge peek interrupt teardown promote archive.
#   For `answer`, the task's current decision token is stamped automatically
#   (staleness guard) unless --decision-id or --no-decision is given.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-inbox-lib.sh
. "$SCRIPT_DIR/fm-inbox-lib.sh"
STATUS_BIN="$SCRIPT_DIR/fm-fleet-status.sh"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: fm-dock.sh requires jq" >&2; exit 1; }
}

# Color only for an interactive, color-allowed terminal; otherwise plain.
COLOR=false
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] && [ -t 1 ]; then
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

# Write one intent, auto-stamping the decision token for answers. Echoes the id.
write_intent() {  # <task> <action> <payload> <intent_id> <decision_id> <want_decision>
  local task=$1 action=$2 payload=$3 id=$4 decision_id=$5 want_decision=$6
  fm_inbox_valid_action "$action" || { echo "error: invalid action: $action" >&2; return 2; }
  [ -n "$id" ] || id=$(fm_inbox_new_id)
  if [ "$action" = answer ] && [ -z "$decision_id" ] && [ "$want_decision" = true ]; then
    decision_id=$(fm_inbox_decision_token "$task")
  fi
  fm_inbox_write "$id" "$task" "$action" "$payload" "$decision_id" ""
}

cmd_submit() {
  require_jq
  local task="" action="" payload="" intent_id="" decision_id="" want_decision=true
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --action) action=${2:-}; shift 2 ;;
      --payload) payload=${2:-}; shift 2 ;;
      --intent-id) intent_id=${2:-}; shift 2 ;;
      --decision-id) decision_id=${2:-}; shift 2 ;;
      --no-decision) want_decision=false; shift ;;
      *) echo "error: unknown submit argument: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$task" ] && [ -n "$action" ] || { echo "usage: fm-dock.sh submit --task <id> --action <action> [--payload <text>]" >&2; return 2; }
  local out
  out=$(write_intent "$task" "$action" "$payload" "$intent_id" "$decision_id" "$want_decision") || return $?
  printf 'queued intent %s (%s for %s)\n' "$out" "$action" "$task"
}

# Interactive loop. Reads plain lines from stdin so it is scriptable and never
# hangs: an EOF on any prompt ends the loop cleanly.
cmd_interactive() {
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
        if id=$(write_intent "$task" "$action" "$payload" "" "" true); then
          printf '%s\n' "$(paint 32 "queued intent $id - firstmate will act on it")"
        else
          printf '%s\n' "$(paint 31 'failed to queue intent')"
        fi
        ;;
      *) printf '%s\n' "$(paint 2 'cancelled')" ;;
    esac
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status) render_digest ;;
  submit) shift; cmd_submit "$@" ;;
  '') cmd_interactive ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
