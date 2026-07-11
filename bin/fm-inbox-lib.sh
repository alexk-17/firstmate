#!/usr/bin/env bash
# fm-inbox-lib.sh - the captain command inbox: shared helpers and the CANONICAL
# schema for the durable intent store behind the Fleet Dock control layer.
#
# The Dock console (bin/fm-dock.sh) writes intents here; firstmate reads,
# executes, and resolves them via bin/fm-inbox-drain.sh; the watcher
# (bin/fm-watch.sh) polls for new pending intents and surfaces them as `inbox`
# wakes. This file is the ONE place the intent format and its state machine are
# defined; every other file cross-references it.
#
# An intent is one JSON object at state/captain-inbox/<intent_id>.json
# (gitignored, like all of state/). The FILENAME STEM MUST EQUAL .intent_id - a
# mismatch is rejected as invalid, so a spoof file cannot borrow another intent's
# id. Fields, all strings unless noted:
#   intent_id    unique idempotency key; also the filename stem.
#   ts           epoch seconds the intent was written (number).
#   task_id      the fleet task the action targets (validated id charset).
#   action       one of: answer note merge peek interrupt teardown promote archive
#                (promote/archive are accepted but not auto-executed).
#   payload      action-specific string (answer text, one-line note/steer; "" for
#                actions that need no payload).
#   decision_id  staleness token for `answer` intents (fm_inbox_decision_token).
#                The Dock stamps the task's current token; the drain rejects a
#                stale one at surface time AND the executor REVALIDATES it
#                immediately before the send, so a stale answer is never applied
#                to a moved gate. Empty for non-answer actions.
#   version      provenance tag ("fm-dock" from the console); carried, surfaced.
#   status       pending | claimed | done | rejected | error (the state machine).
#   result       filled by the processor when it resolves the intent.
#   claim_ts     epoch of the claim (number; present once claimed) - lets the
#                drain re-surface a claim stranded by a crash before resolve.
#
# STATE MACHINE (all transitions are compare-and-swap under one per-inbox lock):
#   (none) -> pending        fm_inbox_write, atomic no-clobber (duplicate id no-op)
#   pending -> claimed       fm_inbox_claim_file, only if still pending
#   {pending,claimed} -> done|rejected|error   fm_inbox_resolve, only from a live
#                             intent to a terminal status; the file then MOVES to
#                             done/ so it leaves the watcher's hot glob. A terminal
#                             intent can never regress back to pending/claimed.
#
# AUTHORITY: the console only writes intents and firstmate is the sole executor;
# destructive/irreversible actions (merge/teardown/interrupt) are never
# auto-executed - see bin/fm-inbox-drain.sh. Idempotency and stale rejection are
# code, never model judgment. jq is required.

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
FM_INBOX_DONE_DIR="$FM_INBOX_DIR/done"
FM_INBOX_LOCK="${FM_INBOX_LOCK:-$STATE/.captain-inbox.lock}"
FM_INBOX_TAB="$(printf '\t')"
# Bounds so a hostile or accidental flood cannot tax the watcher hot loop.
FM_INBOX_MAX_BYTES="${FM_INBOX_MAX_BYTES:-8192}"      # reject/skip files larger than this
FM_INBOX_MAX_PAYLOAD="${FM_INBOX_MAX_PAYLOAD:-4096}"  # reject a payload larger than this at write

# The per-inbox lock reuses the wake queue's portable lock primitives. Source
# fm-wake-lib only if a caller has not already provided them (fm-watch.sh and
# fm-wake-drain.sh source it first), so this never double-sources.
if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_INBOX_LIB_DIR/fm-wake-lib.sh"
fi

fm_inbox_dir() {
  mkdir -p "$FM_INBOX_DIR" 2>/dev/null || true
  printf '%s\n' "$FM_INBOX_DIR"
}

fm_inbox_path() {  # <intent_id>  (top-level path; may not exist once resolved)
  printf '%s/%s.json\n' "$FM_INBOX_DIR" "$1"
}

# Locate an intent by id whether it is live (top-level) or already resolved (done/).
fm_inbox_locate() {  # <intent_id>
  local id=$1
  if [ -f "$FM_INBOX_DIR/$id.json" ]; then printf '%s\n' "$FM_INBOX_DIR/$id.json"; return 0; fi
  if [ -f "$FM_INBOX_DONE_DIR/$id.json" ]; then printf '%s\n' "$FM_INBOX_DONE_DIR/$id.json"; return 0; fi
  return 1
}

# Collision-free seen-marker path: the id is already restricted to a path-safe
# charset (fm_inbox_valid_id), so use it verbatim - never a lossy tr that would
# collapse a-b, a_b, and a.b to one marker.
fm_inbox_seen_marker() {  # <intent_id>
  printf '%s/.seen-inbox-%s\n' "$STATE" "$1"
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

# An id (and a task_id) is used to build a filename or stat a path, so keep it to
# a safe, path-inert charset with no leading dot and no traversal.
fm_inbox_valid_id() {  # <id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .*) return 1 ;;
    *..*) return 1 ;;
    *) return 0 ;;
  esac
}

# Unique, sortable id: epoch seconds plus 6 random bytes of entropy.
fm_inbox_new_id() {
  local rand
  rand=$(od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand=$(printf '%06x%06x' "$((RANDOM))" "$((RANDOM))")
  printf '%s-%s\n' "$(date +%s)" "$rand"
}

# Read one field from an intent file (raw; empty when null/absent). Non-zero exit
# only when the file is missing or unparseable.
fm_inbox_field() {  # <file> <field>
  local file=$1 field=$2 out
  [ -f "$file" ] || return 1
  out=$(jq -r --arg f "$field" '.[$f] // ""' "$file" 2>/dev/null) || return 1
  printf '%s' "$out"
}

fm_inbox_status() {  # <intent_id>
  local f
  f=$(fm_inbox_locate "$1") || return 1
  fm_inbox_field "$f" status
}

# 0 iff <task> has a live meta (fm-spawn writes it, teardown removes it), the
# cheap ground-truth "this task exists and is not torn down" check.
fm_inbox_task_exists() {  # <task_id>
  fm_inbox_valid_id "$1" || return 1
  [ -f "$STATE/$1.meta" ]
}

# 0 iff <task>'s status log's last line is a captain-owned decision gate.
fm_inbox_task_awaiting_decision() {  # <task_id>
  local statusf last
  fm_inbox_valid_id "$1" || return 1
  statusf="$STATE/$1.status"
  [ -f "$statusf" ] || return 1
  last=$(grep -v '^[[:space:]]*$' "$statusf" 2>/dev/null | tail -1)
  case "$last" in
    needs-decision:*|needs-decision) return 0 ;;
    *) return 1 ;;
  esac
}

# Deterministic decision token for a task: the size:mtime signature of its status
# log. Any new status append (the crew resumed, moved to another gate, or
# finished) changes it, so a token captured when an answer was composed no longer
# matches once the gate has moved. Empty when the task has no status log.
fm_inbox_decision_token() {  # <task_id>
  local task=$1 statusf sig
  fm_inbox_valid_id "$task" || { printf ''; return 0; }
  statusf="$STATE/$task.status"
  [ -f "$statusf" ] || { printf ''; return 0; }
  if [ "$(uname)" = Darwin ]; then
    sig=$(stat -f '%z:%m' "$statusf" 2>/dev/null)
  else
    sig=$(stat -c '%s:%Y' "$statusf" 2>/dev/null)
  fi
  printf '%s' "$sig"
}

# Validate a file against the strict schema and print its status when valid;
# non-zero (no output) when invalid. ONE jq call after a cheap size gate, so it
# is safe to run in the watcher's poll. Enforces: object; all string fields
# present as strings; ts a number; a valid action and status enum; and crucially
# the filename stem equals .intent_id, so a spoof file cannot claim another id.
fm_inbox_validate_and_status() {  # <file>
  local file=$1 base stem sz
  [ -f "$file" ] || return 1
  sz=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sz" -le "$FM_INBOX_MAX_BYTES" ] || return 1
  base=$(basename "$file"); stem=${base%.json}
  jq -e -r --arg stem "$stem" '
    if (type=="object"
        and (.intent_id|type=="string") and (.intent_id==$stem)
        and (.task_id|type=="string") and (.task_id!="")
        and (.action|type=="string")
        and (.action as $a | (["answer","note","merge","peek","interrupt","teardown","promote","archive"]|index($a)) != null)
        and (.payload|type=="string")
        and (.decision_id|type=="string")
        and (.version|type=="string")
        and (.result|type=="string")
        and (.status|type=="string")
        and (.status as $s | (["pending","claimed","done","rejected","error"]|index($s)) != null)
        and (.ts|type=="number"))
      then .status
      else error("invalid intent") end
  ' "$file" 2>/dev/null
}

fm_inbox_valid_file() {  # <file>
  fm_inbox_validate_and_status "$1" >/dev/null 2>&1
}

# Write a new pending intent. Atomic and no-clobber under the inbox lock: a
# duplicate intent_id is a true no-op (the existing on-disk intent, which may
# already be claimed/resolved, is never touched, so its meaning is not
# timing-dependent). Echoes the intent_id on success; returns 2 on validation.
fm_inbox_write() {  # <intent_id> <task_id> <action> <payload> [decision_id] [version]
  local id=$1 task=$2 action=$3 payload=$4 decision_id=${5:-} version=${6:-} dir file tmp ts rc
  fm_inbox_valid_id "$id" || { echo "fm_inbox_write: invalid intent_id: $id" >&2; return 2; }
  fm_inbox_valid_id "$task" || { echo "fm_inbox_write: invalid task_id: $task" >&2; return 2; }
  fm_inbox_valid_action "$action" || { echo "fm_inbox_write: invalid action: $action" >&2; return 2; }
  if [ "${#payload}" -gt "$FM_INBOX_MAX_PAYLOAD" ]; then
    echo "fm_inbox_write: payload exceeds $FM_INBOX_MAX_PAYLOAD bytes" >&2; return 2
  fi
  dir=$(fm_inbox_dir)
  file="$dir/$id.json"
  ts=$(date +%s)
  rc=0
  fm_lock_acquire_wait "$FM_INBOX_LOCK"
  if [ -e "$file" ] || [ -e "$FM_INBOX_DONE_DIR/$id.json" ]; then
    fm_lock_release "$FM_INBOX_LOCK"
    printf '%s\n' "$id"
    return 0
  fi
  tmp="$dir/.$id.json.tmp.$$"
  if jq -n \
      --arg intent_id "$id" --argjson ts "$ts" --arg task_id "$task" \
      --arg action "$action" --arg payload "$payload" \
      --arg decision_id "$decision_id" --arg version "$version" \
      '{intent_id:$intent_id, ts:$ts, task_id:$task_id, action:$action,
        payload:$payload, decision_id:$decision_id, version:$version,
        status:"pending", result:""}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
    :
  else
    rm -f "$tmp"; rc=1
  fi
  fm_lock_release "$FM_INBOX_LOCK"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$id"
}

# Compare-and-swap claim of the ENUMERATED file (never a path reconstructed from
# untrusted content): under the lock, claim only if the file is still pending.
# Records claim_ts. Returns non-zero when it is no longer pending (lost the race,
# already claimed, or resolved) so a concurrent drain cannot double-surface it.
fm_inbox_claim_file() {  # <file>
  local file=$1 tmp cur ts rc=1
  [ -f "$file" ] || return 1
  ts=$(date +%s)
  fm_lock_acquire_wait "$FM_INBOX_LOCK"
  cur=$(fm_inbox_field "$file" status 2>/dev/null || true)
  if [ "$cur" = pending ]; then
    tmp="$file.tmp.$$"
    if jq --argjson t "$ts" '.status="claimed" | .claim_ts=$t' "$file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
      rc=0
    else
      rm -f "$tmp"
    fi
  fi
  fm_lock_release "$FM_INBOX_LOCK"
  return "$rc"
}

# CAS re-claim of a crash-stranded claim: under the lock, refresh claim_ts (and
# return 0 so the drain re-surfaces it) ONLY if the intent is still claimed AND
# still stale past <threshold>. Two concurrent drains therefore re-surface a given
# stranded claim at most once: the first refreshes claim_ts, the second sees it is
# no longer stale and returns non-zero. Mirrors the pending-claim CAS guarantee.
fm_inbox_reclaim_stale() {  # <file> <threshold_secs>
  local file=$1 thr=$2 tmp ts ct rc=1
  [ -f "$file" ] || return 1
  case "$thr" in ''|*[!0-9]*) thr=0 ;; esac
  ts=$(date +%s)
  fm_lock_acquire_wait "$FM_INBOX_LOCK"
  if [ "$(fm_inbox_field "$file" status 2>/dev/null || true)" = claimed ]; then
    ct=$(fm_inbox_field "$file" claim_ts 2>/dev/null || true); case "$ct" in ''|*[!0-9]*) ct=0 ;; esac
    if [ "$((ts - ct))" -ge "$thr" ]; then
      tmp="$file.tmp.$$"
      if jq --argjson t "$ts" '.claim_ts=$t' "$file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then rc=0; else rm -f "$tmp"; fi
    fi
  fi
  fm_lock_release "$FM_INBOX_LOCK"
  return "$rc"
}

# Resolve a LIVE intent (pending or claimed) to a terminal status and move it to
# done/ so it leaves the watcher's hot glob. CAS under the lock: refuses to touch
# an already-terminal intent (no done->pending regression) and refuses a
# non-terminal target status. Removes the seen marker.
fm_inbox_resolve() {  # <intent_id> <status> [result]
  local id=$1 status=$2 result=${3:-} file tmp cur rc=1
  fm_inbox_valid_status "$status" || { echo "fm_inbox_resolve: invalid status: $status" >&2; return 2; }
  case "$status" in
    done|rejected|error) ;;
    *) echo "fm_inbox_resolve: target must be terminal (done|rejected|error), not $status" >&2; return 2 ;;
  esac
  file="$FM_INBOX_DIR/$id.json"
  [ -f "$file" ] || { echo "fm_inbox_resolve: no such live intent: $id" >&2; return 1; }
  fm_lock_acquire_wait "$FM_INBOX_LOCK"
  cur=$(fm_inbox_field "$file" status 2>/dev/null || true)
  case "$cur" in
    pending|claimed)
      tmp="$file.tmp.$$"
      if jq --arg s "$status" --arg r "$result" '.status=$s | .result=$r' "$file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
        # File now holds terminal status in place (atomic). Best-effort move it
        # out of the hot glob; the pending/claimed filters ignore it regardless.
        mkdir -p "$FM_INBOX_DONE_DIR" 2>/dev/null || true
        mv -f "$file" "$FM_INBOX_DONE_DIR/$id.json" 2>/dev/null || true
        rm -f "$(fm_inbox_seen_marker "$id")" 2>/dev/null || true
        rc=0
      else
        rm -f "$tmp"
      fi
      ;;
    *)
      echo "fm_inbox_resolve: refusing $cur -> $status for $id (not a live intent)" >&2
      ;;
  esac
  fm_lock_release "$FM_INBOX_LOCK"
  return "$rc"
}

# Emit "<ts>\t<intent_id>\t<file>" for every VALID pending intent, oldest-first.
# Invalid files are skipped silently here (the hot path); cmd_list notes them.
fm_inbox_list_pending() {
  local dir f status ts id
  dir="$FM_INBOX_DIR"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    status=$(fm_inbox_validate_and_status "$f") || continue
    [ "$status" = pending ] || continue
    ts=$(fm_inbox_field "$f" ts)
    id=$(fm_inbox_field "$f" intent_id)
    printf '%s\t%s\t%s\n' "${ts:-0}" "${id:-$(basename "$f" .json)}" "$f"
  done | sort -t"$FM_INBOX_TAB" -k1,1n -k2,2
}

# Emit "<ts>\t<intent_id>\t<file>" for claimed intents whose claim_ts is older
# than <threshold_secs> - a claim stranded by a crash between claim and resolve.
fm_inbox_list_claimed_stale() {  # <threshold_secs>
  local thr=$1 dir f status ct now id ts
  dir="$FM_INBOX_DIR"
  [ -d "$dir" ] || return 0
  case "$thr" in ''|*[!0-9]*) thr=0 ;; esac
  now=$(date +%s)
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    status=$(fm_inbox_validate_and_status "$f") || continue
    [ "$status" = claimed ] || continue
    ct=$(fm_inbox_field "$f" claim_ts); case "$ct" in ''|*[!0-9]*) ct=0 ;; esac
    [ "$((now - ct))" -ge "$thr" ] || continue
    id=$(fm_inbox_field "$f" intent_id); ts=$(fm_inbox_field "$f" ts)
    printf '%s\t%s\t%s\n' "${ts:-0}" "${id:-$(basename "$f" .json)}" "$f"
  done | sort -t"$FM_INBOX_TAB" -k1,1n -k2,2
}

# 0 iff the inbox holds at least one pending intent (cheap; read-only).
fm_inbox_has_pending() {
  [ -n "$(fm_inbox_list_pending)" ]
}

# 0 iff the inbox holds at least one claimed intent stranded past <threshold>.
fm_inbox_has_stranded_claims() {  # <threshold_secs>
  [ -n "$(fm_inbox_list_claimed_stale "${1:-0}")" ]
}
