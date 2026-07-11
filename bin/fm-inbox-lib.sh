#!/usr/bin/env bash
# fm-inbox-lib.sh - the captain command inbox: shared helpers and the CANONICAL
# schema for the durable intent store behind the Fleet Dock control layer.
#
# The Dock console (bin/fm-dock.sh) writes intents here; firstmate reads and
# executes them via bin/fm-inbox-drain.sh; the watcher (bin/fm-watch.sh) polls
# for new pending intents and surfaces them as `inbox` wakes. This file is the
# ONE place the intent format is defined; every other file cross-references it.
#
# An intent is one JSON object at state/captain-inbox/<intent_id>.json
# (gitignored, like all of state/). Fields:
#   intent_id    unique idempotency key; also the filename stem. A duplicate
#                intent_id write is a no-op (never clobbers an existing intent).
#   ts           epoch seconds the intent was written.
#   task_id      the fleet task the action targets.
#   action       one of: answer note merge peek interrupt teardown promote archive
#                (promote/archive are accepted but the executor may stub them).
#   payload      action-specific string (answer text, note/steer line; "" for
#                actions that need no payload such as peek/merge/interrupt/teardown).
#   decision_id  optional staleness token for `answer` intents. The Dock stamps
#                the task's current decision token (fm_inbox_decision_token) at
#                compose time; the drain re-checks it and REJECTS the intent if
#                the task has moved past that gate, so a stale answer is never
#                mis-applied to a different decision. Empty means "no staleness
#                guard" (non-answer actions leave it empty).
#   version      optional free-form caller version tag; carried, not interpreted.
#   status       pending | claimed | done | rejected | error. The console writes
#                pending; the drain claims (claimed) or auto-rejects a stale
#                answer (rejected); firstmate resolves to done/rejected/error.
#   result       filled by the processor when it resolves the intent.
#
# The console NEVER touches crewmates, PRs, or worktrees: it only writes intents.
# Firstmate is the sole executor, so the authority rules and safety gates of
# AGENTS.md (destructive/irreversible/security-sensitive actions still escalate
# to the captain) are preserved - the inbox only CARRIES a request.
#
# Idempotency + safety are code, never model judgment: a duplicate intent_id is a
# byte-cheap no-op here, and a stale decision_id is a deterministic reject in the
# drain (both are testable without an LLM).
#
# All reads/writes go through jq; callers that need the inbox must have jq.

FM_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_INBOX_DEFAULT_ROOT="$(cd "$FM_INBOX_LIB_DIR/.." && pwd)"
# Respect an already-set FM_ROOT/FM_HOME/STATE (fm-watch.sh sets STATE before
# sourcing this), and the same FM_*_OVERRIDE knobs the rest of the toolbelt uses.
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_INBOX_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
# The inbox dir is derived from STATE and NOT created at source time (so merely
# sourcing this from the watcher never fabricates an empty dir); writers create
# it lazily via fm_inbox_dir.
FM_INBOX_DIR="${FM_INBOX_DIR:-$STATE/captain-inbox}"

FM_INBOX_TAB="$(printf '\t')"

fm_inbox_dir() {
  mkdir -p "$FM_INBOX_DIR" 2>/dev/null || true
  printf '%s\n' "$FM_INBOX_DIR"
}

fm_inbox_path() {  # <intent_id>
  printf '%s/%s.json\n' "$FM_INBOX_DIR" "$1"
}

fm_inbox_valid_action() {  # <action>
  case "$1" in
    answer|note|merge|peek|interrupt|teardown|promote|archive) return 0 ;;
    *) return 1 ;;
  esac
}

fm_inbox_valid_status() {  # <status>
  case "$1" in
    pending|claimed|done|rejected|error) return 0 ;;
    *) return 1 ;;
  esac
}

# An id is also a filename stem, so keep it to a safe, path-inert charset.
fm_inbox_valid_id() {  # <intent_id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .*) return 1 ;;
    *) return 0 ;;
  esac
}

# Unique, sortable id: epoch seconds plus 6 random bytes of entropy. Two intents
# submitted in the same second still get distinct ids.
fm_inbox_new_id() {
  local rand
  rand=$(od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand=$(printf '%06x%06x' "$((RANDOM))" "$((RANDOM))")
  printf '%s-%s\n' "$(date +%s)" "$rand"
}

# Read one field from an intent file (raw; empty string when null/absent).
# Non-zero exit only when the file is missing or unparseable.
fm_inbox_field() {  # <file> <field>
  local file=$1 field=$2 out
  [ -f "$file" ] || return 1
  out=$(jq -r --arg f "$field" '.[$f] // ""' "$file" 2>/dev/null) || return 1
  printf '%s' "$out"
}

fm_inbox_status() {  # <intent_id>
  fm_inbox_field "$(fm_inbox_path "$1")" status
}

# Deterministic decision token for a task: the size:mtime signature of its status
# log. Any new status append (the crew resumed, moved to a different gate, or
# finished) changes the signature, so a token captured when an answer was composed
# no longer matches once the gate has moved. Empty when the task has no status log.
fm_inbox_decision_token() {  # <task_id>
  local task=$1 statusf sig
  statusf="$STATE/$task.status"
  [ -f "$statusf" ] || { printf ''; return 0; }
  if [ "$(uname)" = Darwin ]; then
    sig=$(stat -f '%z:%m' "$statusf" 2>/dev/null)
  else
    sig=$(stat -c '%s:%Y' "$statusf" 2>/dev/null)
  fi
  printf '%s' "$sig"
}

# Write a new pending intent atomically. Idempotent: an existing intent_id is a
# no-op (the on-disk intent, which may already be claimed/resolved, is untouched).
# Echoes the intent_id on success. Returns 2 on a validation error.
fm_inbox_write() {  # <intent_id> <task_id> <action> <payload> [decision_id] [version]
  local id=$1 task=$2 action=$3 payload=$4 decision_id=${5:-} version=${6:-} dir file tmp ts
  fm_inbox_valid_id "$id" || { echo "fm_inbox_write: invalid intent_id: $id" >&2; return 2; }
  fm_inbox_valid_action "$action" || { echo "fm_inbox_write: invalid action: $action" >&2; return 2; }
  [ -n "$task" ] || { echo "fm_inbox_write: empty task_id" >&2; return 2; }
  dir=$(fm_inbox_dir)
  file="$dir/$id.json"
  if [ -e "$file" ]; then
    # Idempotent no-op. intent_ids are unique per submission, so the only way here
    # is a deliberate re-submit of the same id; never overwrite the prior intent.
    printf '%s\n' "$id"
    return 0
  fi
  ts=$(date +%s)
  tmp="$dir/.$id.json.tmp.$$"
  if ! jq -n \
      --arg intent_id "$id" --argjson ts "$ts" --arg task_id "$task" \
      --arg action "$action" --arg payload "$payload" \
      --arg decision_id "$decision_id" --arg version "$version" \
      '{intent_id:$intent_id, ts:$ts, task_id:$task_id, action:$action,
        payload:$payload, decision_id:$decision_id, version:$version,
        status:"pending", result:""}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$id"
}

# Set status=claimed without touching result. Used by the drain when it surfaces
# an intent so the same one is never surfaced twice.
fm_inbox_claim() {  # <intent_id>
  local id=$1 dir file tmp
  dir=$(fm_inbox_dir); file="$dir/$id.json"
  [ -f "$file" ] || return 1
  tmp="$dir/.$id.json.tmp.$$"
  jq '.status="claimed"' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Resolve an intent to a terminal (or corrected) status with a result string.
fm_inbox_resolve() {  # <intent_id> <status> [result]
  local id=$1 status=$2 result=${3:-} dir file tmp
  fm_inbox_valid_status "$status" || { echo "fm_inbox_resolve: invalid status: $status" >&2; return 2; }
  dir=$(fm_inbox_dir); file="$dir/$id.json"
  [ -f "$file" ] || { echo "fm_inbox_resolve: no such intent: $id" >&2; return 1; }
  tmp="$dir/.$id.json.tmp.$$"
  jq --arg s "$status" --arg r "$result" '.status=$s | .result=$r' "$file" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Emit "<ts>\t<intent_id>\t<file>" for every pending intent, oldest-first
# (numeric ts, then id). Read-only: never creates the inbox dir.
fm_inbox_list_pending() {
  local dir f st ts id
  dir="$FM_INBOX_DIR"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    st=$(fm_inbox_field "$f" status) || continue
    [ "$st" = pending ] || continue
    ts=$(fm_inbox_field "$f" ts)
    id=$(fm_inbox_field "$f" intent_id)
    printf '%s\t%s\t%s\n' "${ts:-0}" "${id:-$(basename "$f" .json)}" "$f"
  done | sort -t"$FM_INBOX_TAB" -k1,1n -k2,2
}

# 0 iff the inbox holds at least one pending intent (cheap; read-only).
fm_inbox_has_pending() {
  [ -n "$(fm_inbox_list_pending)" ]
}
