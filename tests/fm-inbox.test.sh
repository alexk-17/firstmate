#!/usr/bin/env bash
# tests/fm-inbox.test.sh - the captain command inbox behind the Fleet Dock
# control layer (bin/fm-inbox-lib.sh, bin/fm-inbox-drain.sh, and the watcher's
# inbox poll in bin/fm-watch.sh).
#
# Pins the contract that makes captain commands safe to carry through firstmate:
#   - a duplicate intent_id is an idempotent no-op (never clobbers a prior intent);
#   - an `answer` whose recorded decision token no longer matches the task's
#     current one is deterministically REJECTED, never surfaced or mis-applied;
#   - the drain surfaces + claims a pending intent exactly once, then --resolve
#     records the outcome;
#   - the watcher notices a new pending intent and enqueues a durable `inbox`
#     wake (enqueue-before-suppress), and does not re-surface an already-seen one;
#   - the inbox poll is inert when no inbox dir exists, so it cannot perturb the
#     existing signal/stale/check/heartbeat paths.
# Reuses the wake-queue fixture harness (make_case) so the watcher runs hermetically.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LIB="$ROOT/bin/fm-inbox-lib.sh"
DRAIN="$ROOT/bin/fm-inbox-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox-tests)

# Write a pending intent through the library's own writer, scoped to <state>.
inbox_write() {  # <state> <id> <task> <action> <payload> [decision_id]
  local state=$1 id=$2 task=$3 action=$4 payload=$5 decision=${6:-}
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_inbox_write "$2" "$3" "$4" "$5" "$6" "" >/dev/null
  ' _ "$LIB" "$id" "$task" "$action" "$payload" "$decision"
}

field() {  # <file> <field>
  jq -r --arg f "$2" '.[$f]' "$1"
}

json_count() {  # <dir>
  local n=0 f
  for f in "$1"/*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

new_state() {
  local d
  d=$(mktemp -d "$TMP_ROOT/state.XXXXXX")
  printf '%s\n' "$d"
}

# --- Component A: schema + idempotency + stale token ------------------------

test_idempotent_duplicate_write() {
  local state file
  state=$(new_state)
  inbox_write "$state" dup-1 fix-login-k3 note "first text"
  inbox_write "$state" dup-1 fix-login-k3 note "SECOND text overwrites?"
  file="$state/captain-inbox/dup-1.json"
  [ "$(field "$file" payload)" = "first text" ] \
    || fail "duplicate intent_id must be a no-op, but the payload was overwritten"
  [ "$(json_count "$state/captain-inbox")" = 1 ] \
    || fail "duplicate intent_id created a second intent file"
  pass "a duplicate intent_id is an idempotent no-op"
}

test_invalid_action_and_id_rejected() {
  local state rc
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_write good-id t1 frobnicate "x" "" ""' _ "$LIB" 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ] || fail "invalid action must be rejected with exit 2, got $rc"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_write "bad/id" t1 note "x" "" ""' _ "$LIB" 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ] || fail "a path-unsafe intent_id must be rejected with exit 2, got $rc"
  [ ! -d "$state/captain-inbox" ] || [ -z "$(ls -A "$state/captain-inbox" 2>/dev/null)" ] \
    || fail "a rejected write must not leave an intent file"
  pass "invalid action and path-unsafe intent_id are both rejected"
}

test_decision_token_changes_on_status_append() {
  local state t1 t2
  state=$(new_state)
  printf 'needs-decision: A or B\n' > "$state/decide.status"
  t1=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_decision_token decide' _ "$LIB")
  [ -n "$t1" ] || fail "decision token must be non-empty for a task with a status log"
  sleep 1
  printf 'done: shipped\n' >> "$state/decide.status"
  t2=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_decision_token decide' _ "$LIB")
  [ "$t1" != "$t2" ] || fail "decision token must change after a new status line is appended"
  pass "decision token tracks status-log transitions (the staleness signal)"
}

# --- Component B: drain surface / claim / stale-reject / resolve ------------

test_drain_surfaces_and_claims_once() {
  local state out out2 file
  state=$(new_state)
  inbox_write "$state" note-1 fix-login-k3 note "please rebase"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  printf '%s' "$out" | jq -e '.intent_id == "note-1" and .action == "note" and .payload == "please rebase"' >/dev/null \
    || fail "drain did not surface the pending intent as one actionable record"
  file="$state/captain-inbox/note-1.json"
  [ "$(field "$file" status)" = claimed ] || fail "drain did not mark the surfaced intent claimed"
  out2=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ -z "$out2" ] || fail "a claimed intent was surfaced a second time: $out2"
  pass "drain surfaces a pending intent as one record and claims it (never twice)"
}

test_drain_rejects_stale_answer() {
  local state out file
  state=$(new_state)
  printf 'needs-decision: A or B\n' > "$state/decide.status"
  # Stamp the answer with the CURRENT token, then move the gate on.
  local tok
  tok=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_decision_token decide' _ "$LIB")
  inbox_write "$state" ans-stale decide answer "go with A" "$tok"
  sleep 1
  printf 'done: shipped\n' >> "$state/decide.status"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ -z "$out" ] || fail "a stale answer must NOT be surfaced, but drain emitted: $out"
  file="$state/captain-inbox/ans-stale.json"
  [ "$(field "$file" status)" = rejected ] || fail "a stale answer must be auto-rejected"
  case "$(field "$file" result)" in *stale*) : ;; *) fail "rejected answer must record why it was stale" ;; esac
  pass "an answer whose gate moved on is rejected, never mis-applied"
}

test_drain_surfaces_fresh_answer() {
  local state out
  state=$(new_state)
  printf 'needs-decision: C or D\n' > "$state/decide2.status"
  local tok
  tok=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_inbox_decision_token decide2' _ "$LIB")
  inbox_write "$state" ans-fresh decide2 answer "go with C" "$tok"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  printf '%s' "$out" | jq -e '.intent_id == "ans-fresh" and .action == "answer"' >/dev/null \
    || fail "a fresh answer (token still current) must be surfaced"
  pass "a non-stale answer is surfaced normally"
}

test_resolve_records_outcome() {
  local state file rc
  state=$(new_state)
  inbox_write "$state" res-1 t1 note "steer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve res-1 "done" "relayed to crew"
  file="$state/captain-inbox/res-1.json"
  [ "$(field "$file" status)" = "done" ] || fail "--resolve did not set status"
  [ "$(field "$file" result)" = "relayed to crew" ] || fail "--resolve did not set result"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve res-1 bogus "x" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "--resolve must reject an invalid status with exit 2, got $rc"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve nosuch "done" "x" 2>/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "--resolve must fail on an unknown intent id, got $rc"
  pass "--resolve records status+result and rejects bad status / unknown id"
}

test_list_and_show_are_readonly() {
  local state out file
  state=$(new_state)
  inbox_write "$state" ls-1 taskA peek ""
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" --list)
  printf '%s' "$out" | grep -F "ls-1" | grep -F "peek" >/dev/null || fail "--list did not list the pending intent"
  file="$state/captain-inbox/ls-1.json"
  [ "$(field "$file" status)" = pending ] || fail "--list must not claim (read-only)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --show ls-1 | jq -e '.intent_id == "ls-1"' >/dev/null \
    || fail "--show did not print the intent JSON"
  [ "$(field "$file" status)" = pending ] || fail "--show must not mutate the intent (read-only)"
  pass "--list and --show are read-only (never claim)"
}

# --- watcher inbox-wake path ------------------------------------------------

# Run the watcher hermetically with everything but the inbox poll silenced.
run_watch_once() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40
}

test_watcher_enqueues_inbox_wake() {
  local dir state fakebin out drain_out key
  dir=$(make_case inbox-wake)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  inbox_write "$state" wake-1 fix-login-k3 note "please rebase"
  run_watch_once "$state" "$fakebin" "$out" || fail "watcher did not exit on a pending inbox intent"
  grep -F "inbox:" "$out" >/dev/null || fail "watcher did not print an inbox wake reason"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null || fail "wake drain after inbox wake failed"
  grep "$(printf '\tinbox\t')" "$drain_out" | grep -F "wake-1" >/dev/null || fail "inbox wake was not queued as an inbox record"
  key=$(printf '%s' wake-1 | tr -c 'A-Za-z0-9' '_')
  [ -s "$state/.seen-inbox-$key" ] || fail "the per-intent seen marker was not written after the enqueue"
  pass "watcher enqueues a durable inbox wake for a new pending intent"
}

test_watcher_does_not_resurface_seen_intent() {
  local dir state fakebin out
  dir=$(make_case inbox-seen)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  inbox_write "$state" seen-1 t1 note "x"
  run_watch_once "$state" "$fakebin" "$out" || fail "first watcher run did not exit"
  grep -F "inbox:" "$out" >/dev/null || fail "first run did not surface the intent"
  # Drain the queue and run again: the still-pending intent must NOT re-fire
  # (its seen marker suppresses it), so the watcher has no inbox wake to exit on.
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>/dev/null
  : > "$out"
  local rc
  run_watch_once "$state" "$fakebin" "$out"; rc=$?
  if [ "$rc" -eq 0 ] && grep -F "inbox:" "$out" >/dev/null; then
    fail "an already-surfaced pending intent was re-enqueued (seen marker ignored)"
  fi
  pass "an already-surfaced pending intent is not re-enqueued"
}

test_watcher_inbox_poll_inert_without_dir() {
  local dir state fakebin out rc
  dir=$(make_case inbox-inert)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  [ ! -d "$state/captain-inbox" ] || fail "fixture unexpectedly has an inbox dir"
  run_watch_once "$state" "$fakebin" "$out"; rc=$?
  # No inbox dir, no signals, no checks, no windows, no heartbeat due: the watcher
  # should keep blocking until we kill it (wait_for_exit returns 124), and never
  # print an inbox wake.
  [ "$rc" -eq 124 ] || fail "watcher exited unexpectedly with no work to do (rc=$rc): $(cat "$out")"
  ! grep -F "inbox:" "$out" >/dev/null || fail "watcher printed an inbox wake with no inbox dir"
  pass "the inbox poll is inert with no inbox dir (existing paths undisturbed)"
}

test_idempotent_duplicate_write
test_invalid_action_and_id_rejected
test_decision_token_changes_on_status_append
test_drain_surfaces_and_claims_once
test_drain_rejects_stale_answer
test_drain_surfaces_fresh_answer
test_resolve_records_outcome
test_list_and_show_are_readonly
test_watcher_enqueues_inbox_wake
test_watcher_does_not_resurface_seen_intent
test_watcher_inbox_poll_inert_without_dir
