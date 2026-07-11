#!/usr/bin/env bash
# tests/fm-inbox.test.sh - the captain command inbox behind the Fleet Dock
# control layer (bin/fm-inbox-lib.sh, bin/fm-inbox-drain.sh, and the watcher's
# inbox poll in bin/fm-watch.sh).
#
# Pins the safety contract, including the races and crash paths the two
# adversarial reviews reproduced:
#   - idempotent write, atomic and no-clobber even under CONCURRENT same-id writers;
#   - strict schema + filename-stem==intent_id, so a spoof file cannot borrow an id;
#   - oversized/malformed files are skipped (never crash, never mis-parsed);
#   - the drain CAS-claims, so CONCURRENT drains never double-emit an intent;
#   - resolve is a one-way transition to a terminal status (no done->pending
#     regression), and moves the intent to done/ so it leaves the watcher glob;
#   - a claim stranded by a crash between claim and resolve is re-surfaced;
#   - an answer's decision token is REVALIDATED at execution, right before the send;
#   - the destructive actions are never auto-executed;
#   - collision-free seen markers; the watcher poll is bounded and inert without
#     the dir; and the enqueue-before-suppress ordering holds.
# Reuses the wake-queue fixture harness (make_case) so the watcher runs hermetically.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LIB="$ROOT/bin/fm-inbox-lib.sh"
DRAIN="$ROOT/bin/fm-inbox-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox-tests)

# --- helpers ----------------------------------------------------------------

# Write a pending intent through the library's own writer, scoped to <state>.
inbox_write() {  # <state> <id> <task> <action> <payload> [decision_id]
  local state=$1 id=$2 task=$3 action=$4 payload=$5 decision=${6:-}
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_inbox_write "$2" "$3" "$4" "$5" "$6" "" >/dev/null
  ' _ "$LIB" "$id" "$task" "$action" "$payload" "$decision"
}

lib_call() {  # <state> <function-and-args...>
  local state=$1; shift
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090
    . "$1"; shift
    "$@"
  ' _ "$LIB" "$@"
}

# Read a field from an intent that may be live or resolved (done/).
field_of() {  # <state> <id> <field>
  local state=$1 id=$2 f=$3 file
  file="$state/captain-inbox/$id.json"
  [ -f "$file" ] || file="$state/captain-inbox/done/$id.json"
  jq -r --arg f "$f" '.[$f] // ""' "$file" 2>/dev/null
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

# A fake fm-send recorder for --execute tests: logs "target|text" to FM_SEND_LOG
# and exits 0, or non-zero when FM_SEND_FAIL is set.
make_fake_send() {  # <dir>
  local d=$1
  cat > "$d/fake-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${1:-}" "${2:-}" >> "${FM_SEND_LOG:-/dev/null}"
[ -n "${FM_SEND_FAIL:-}" ] && exit 1
exit 0
SH
  chmod +x "$d/fake-send.sh"
  printf '%s\n' "$d/fake-send.sh"
}

# --- Component A: schema, idempotency, atomic no-clobber --------------------

test_idempotent_duplicate_write() {
  local state
  state=$(new_state)
  inbox_write "$state" dup-1 taskA note "first text"
  inbox_write "$state" dup-1 taskA note "SECOND text overwrites?"
  [ "$(field_of "$state" dup-1 payload)" = "first text" ] \
    || fail "duplicate intent_id must be a no-op, but the payload was overwritten"
  [ "$(json_count "$state/captain-inbox")" = 1 ] || fail "duplicate intent_id created a second intent file"
  pass "a duplicate intent_id is an idempotent no-op"
}

# C4: concurrent writers with the same id must never clobber - exactly one file,
# and its content is one complete writer's payload (never torn or replaced).
test_concurrent_duplicate_write_no_clobber() {
  local state p
  state=$(new_state)
  ( inbox_write "$state" race taskA note "AAAAA" ) &
  ( inbox_write "$state" race taskA note "BBBBB" ) &
  wait
  [ "$(json_count "$state/captain-inbox")" = 1 ] || fail "concurrent same-id writers created more than one file"
  p=$(field_of "$state" race payload)
  case "$p" in AAAAA|BBBBB) : ;; *) fail "no-clobber write produced a torn/empty payload: '$p'" ;; esac
  pass "concurrent same-id writes are atomic and no-clobber (exactly one, never torn)"
}

test_invalid_action_task_and_id_rejected() {
  local state rc
  state=$(new_state)
  lib_call "$state" fm_inbox_write good-id t1 frobnicate "x" "" "" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "invalid action must be rejected with exit 2, got $rc"
  lib_call "$state" fm_inbox_write "bad/id" t1 note "x" "" "" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "a path-unsafe intent_id must be rejected with exit 2, got $rc"
  lib_call "$state" fm_inbox_write okid "../evil" note "x" "" "" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "a path-traversal task_id must be rejected with exit 2, got $rc"
  [ ! -d "$state/captain-inbox" ] || [ "$(json_count "$state/captain-inbox")" = 0 ] \
    || fail "a rejected write must not leave an intent file"
  pass "invalid action, path-unsafe id, and traversal task_id are all rejected"
}

test_oversized_payload_rejected() {
  local state big rc
  state=$(new_state)
  big=$(head -c 5000 /dev/zero | tr '\0' 'x')
  lib_call "$state" fm_inbox_write big-1 taskA note "$big" "" "" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "an oversized payload must be rejected with exit 2, got $rc"
  pass "an oversized payload is rejected at write"
}

# C5: a spoof file whose stem != embedded intent_id is invalid; it is never
# enumerated, claimed, or emitted, and the legitimately-named file is emitted once.
test_strict_schema_stem_spoof_rejected() {
  local state out
  state=$(new_state)
  inbox_write "$state" legit taskA note "real payload"
  jq -n '{intent_id:"legit",ts:1,task_id:"taskA",action:"note",payload:"SPOOF",decision_id:"",version:"",status:"pending",result:""}' \
    > "$state/captain-inbox/spoof.json"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "spoof drain emitted != 1 record: $out"
  printf '%s' "$out" | jq -e '.intent_id == "legit" and .payload == "real payload"' >/dev/null \
    || fail "the spoof file's contents were surfaced under the legit id"
  [ "$(jq -r '.status' "$state/captain-inbox/spoof.json")" = pending ] \
    || fail "the invalid spoof file must be left untouched (never claimed)"
  pass "a filename-stem/intent_id mismatch is rejected, not claimed under the borrowed id"
}

test_malformed_file_skipped_and_noted() {
  local state err
  state=$(new_state); mkdir -p "$state/captain-inbox"
  printf '{ this is not valid json' > "$state/captain-inbox/broken.json"
  head -c 64 /dev/urandom > "$state/captain-inbox/binary.json"
  inbox_write "$state" ok-1 taskA note "fine"
  [ "$(FM_STATE_OVERRIDE="$state" "$DRAIN" | jq -r '.intent_id' | grep -c .)" = 1 ] \
    || fail "a malformed file must not block the valid intent"
  err=$(FM_STATE_OVERRIDE="$state" "$DRAIN" --list 2>&1 >/dev/null)
  case "$err" in *unparseable/invalid*) : ;; *) fail "--list must note the unparseable files" ;; esac
  pass "malformed/binary files are skipped and noted, never mis-parsed"
}

test_decision_token_changes_on_status_append() {
  local state t1 t2
  state=$(new_state)
  printf 'needs-decision: A or B\n' > "$state/decide.status"
  t1=$(lib_call "$state" fm_inbox_decision_token decide)
  [ -n "$t1" ] || fail "decision token must be non-empty for a task with a status log"
  sleep 1
  printf 'done: shipped\n' >> "$state/decide.status"
  t2=$(lib_call "$state" fm_inbox_decision_token decide)
  [ "$t1" != "$t2" ] || fail "decision token must change after a new status line is appended"
  pass "decision token tracks status-log transitions (the staleness signal)"
}

test_collision_free_seen_marker() {
  local state m1 m2 m3
  state=$(new_state)
  m1=$(lib_call "$state" fm_inbox_seen_marker "a-b")
  m2=$(lib_call "$state" fm_inbox_seen_marker "a_b")
  m3=$(lib_call "$state" fm_inbox_seen_marker "a.b")
  [ "$m1" != "$m2" ] && [ "$m2" != "$m3" ] && [ "$m1" != "$m3" ] \
    || fail "seen markers for a-b, a_b, a.b must be distinct (no lossy collapse): $m1 $m2 $m3"
  pass "seen-marker names are collision-free across punctuation variants"
}

# --- Component B: drain surface / CAS-claim / resolve / recover -------------

test_drain_surfaces_and_claims_once() {
  local state out out2
  state=$(new_state)
  inbox_write "$state" note-1 taskA note "please rebase"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  printf '%s' "$out" | jq -e '.intent_id == "note-1" and .action == "note" and .payload == "please rebase"' >/dev/null \
    || fail "drain did not surface the pending intent as one actionable record"
  [ "$(field_of "$state" note-1 status)" = claimed ] || fail "drain did not mark the surfaced intent claimed"
  out2=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ -z "$out2" ] || fail "a claimed intent was surfaced a second time: $out2"
  pass "drain surfaces a pending intent as one record and CAS-claims it"
}

# B3: two concurrent drains over N pending intents must together emit each intent
# exactly once - no double-surface.
test_concurrent_drains_no_double_emit() {
  local state i total uniq
  state=$(new_state)
  i=0; while [ "$i" -lt 40 ]; do inbox_write "$state" "c$i" taskA note "n$i"; i=$((i + 1)); done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/d1.out" &
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/d2.out" &
  wait
  cat "$state/d1.out" "$state/d2.out" > "$state/all.out"
  total=$(grep -c . "$state/all.out")
  uniq=$(jq -r '.intent_id' "$state/all.out" | sort -u | grep -c .)
  [ "$total" = 40 ] || fail "concurrent drains emitted $total records, expected 40 (double-emit or loss)"
  [ "$uniq" = 40 ] || fail "concurrent drains emitted $uniq unique ids, expected 40"
  pass "concurrent drains CAS-claim: every intent emitted exactly once"
}

test_drain_rejects_stale_answer() {
  local state out
  state=$(new_state)
  printf 'needs-decision: A or B\n' > "$state/decide.status"
  local tok; tok=$(lib_call "$state" fm_inbox_decision_token decide)
  inbox_write "$state" ans-stale decide answer "go with A" "$tok"
  sleep 1
  printf 'done: shipped\n' >> "$state/decide.status"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  [ -z "$out" ] || fail "a stale answer must NOT be surfaced, but drain emitted: $out"
  [ "$(field_of "$state" ans-stale status)" = rejected ] || fail "a stale answer must be auto-rejected"
  case "$(field_of "$state" ans-stale result)" in *stale*) : ;; *) fail "rejected answer must record why" ;; esac
  pass "an answer whose gate moved on is rejected at drain, never mis-applied"
}

test_drain_surfaces_fresh_answer() {
  local state out
  state=$(new_state)
  printf 'needs-decision: C or D\n' > "$state/decide2.status"
  local tok; tok=$(lib_call "$state" fm_inbox_decision_token decide2)
  inbox_write "$state" ans-fresh decide2 answer "go with C" "$tok"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN")
  printf '%s' "$out" | jq -e '.intent_id == "ans-fresh" and .action == "answer"' >/dev/null \
    || fail "a fresh answer (token still current) must be surfaced"
  pass "a non-stale answer is surfaced normally"
}

# C2: resolve is a one-way transition to a terminal status; a terminal intent can
# never regress back to pending/claimed.
test_resolve_terminal_only_no_regression() {
  local state rc
  state=$(new_state)
  inbox_write "$state" res-1 taskA note "steer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null           # claim
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve res-1 "done" "relayed"
  [ "$(field_of "$state" res-1 status)" = "done" ] || fail "--resolve did not set the terminal status"
  [ "$(field_of "$state" res-1 result)" = "relayed" ] || fail "--resolve did not set the result"
  lib_call "$state" fm_inbox_resolve res-1 pending "regress" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "resolve must refuse a non-terminal target (done->pending)"
  lib_call "$state" fm_inbox_resolve res-1 "done" "again" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "resolve must refuse to re-resolve an already-terminal intent"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve res-1 badstatus "x" 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "--resolve must reject an invalid status with exit 2, got $rc"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve nosuch "done" "x" 2>/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "--resolve must fail on an unknown intent id, got $rc"
  pass "resolve is terminal-only, one-way, and rejects bad status / unknown id"
}

# S1: a resolved intent moves to done/ (out of the watcher's hot glob) and its
# seen marker is cleared.
test_resolve_prunes_to_done_dir() {
  local state marker
  state=$(new_state)
  inbox_write "$state" prune-1 taskA note "x"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null
  marker=$(lib_call "$state" fm_inbox_seen_marker prune-1)
  printf 'sig' > "$marker"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve prune-1 "done" "ok"
  [ ! -f "$state/captain-inbox/prune-1.json" ] || fail "resolved intent must leave the top-level dir"
  [ -f "$state/captain-inbox/done/prune-1.json" ] || fail "resolved intent must land in done/"
  [ ! -e "$marker" ] || fail "resolve must clear the seen marker"
  pass "resolve moves the intent to done/ and clears its seen marker"
}

# B2: a claim stranded by a crash between claim and resolve is re-surfaced by a
# later drain past the reclaim window (and never before it).
test_crash_stranded_claim_resurfaced() {
  local state
  state=$(new_state)
  inbox_write "$state" strand-1 taskA note "steer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null            # claim, then "crash" (never resolve)
  [ "$(field_of "$state" strand-1 status)" = claimed ] || fail "intent should be claimed after the drain"
  [ -z "$(FM_STATE_OVERRIDE="$state" "$DRAIN")" ] \
    || fail "a fresh claim must NOT be re-surfaced before the reclaim window"
  FM_STATE_OVERRIDE="$state" FM_INBOX_RECLAIM_SECS=0 "$DRAIN" | grep -q strand-1 \
    || fail "a stranded claim past the reclaim window must be re-surfaced"
  # Two concurrent reclaim drains must re-surface the stranded claim at most once
  # (CAS reclaim): the first refreshes claim_ts to now, the second then sees it is
  # no longer stale and skips. Backdate claim_ts far past a large window so the
  # inter-drain gap cannot re-trigger staleness (deterministic, as with the real
  # 900s window where the seconds-long gap is negligible).
  local f2
  inbox_write "$state" strand-2 taskA note "steer2"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null                    # claim strand-2
  f2="$state/captain-inbox/strand-2.json"
  jq '.claim_ts = 1' "$f2" > "$f2.bak" && mv "$f2.bak" "$f2"        # claim_ts = epoch 1 (ancient)
  FM_STATE_OVERRIDE="$state" FM_INBOX_RECLAIM_SECS=300 "$DRAIN" 2>/dev/null | grep strand-2 > "$state/rc1" &
  FM_STATE_OVERRIDE="$state" FM_INBOX_RECLAIM_SECS=300 "$DRAIN" 2>/dev/null | grep strand-2 > "$state/rc2" &
  wait
  [ "$(cat "$state/rc1" "$state/rc2" | grep -c strand-2)" -le 1 ] \
    || fail "concurrent reclaim drains double-surfaced a stranded claim (CAS reclaim failed)"
  [ "$(cat "$state/rc1" "$state/rc2" | grep -c strand-2)" -ge 1 ] \
    || fail "the stranded claim was not re-surfaced at all under concurrent reclaim"
  pass "a crash-stranded claim is re-surfaced past the window (once, even under concurrent reclaim)"
}

test_list_and_show_readonly_and_find_done() {
  local state
  state=$(new_state)
  inbox_write "$state" ls-1 taskA peek ""
  FM_STATE_OVERRIDE="$state" "$DRAIN" --list | grep -F "ls-1" | grep -F "peek" >/dev/null \
    || fail "--list did not list the pending intent"
  [ "$(field_of "$state" ls-1 status)" = pending ] || fail "--list must not claim (read-only)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" --resolve ls-1 "done" "ok"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --show ls-1 | jq -e '.intent_id == "ls-1" and .status == "done"' >/dev/null \
    || fail "--show must find a resolved intent in done/"
  pass "--list is read-only; --show locates live and resolved intents"
}

# --- Execution path (C3, C8) ------------------------------------------------

test_execute_note_dispatches_via_send() {
  local state fake log
  state=$(new_state)
  fake=$(make_fake_send "$state"); log="$state/send.log"
  printf 'window=x:fm-t1\nkind=ship\n' > "$state/t1.meta"
  inbox_write "$state" exec-note t1 note "rebase now"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null            # claim
  FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" FM_INBOX_SEND_BIN="$fake" "$DRAIN" --execute exec-note \
    || fail "--execute note failed"
  [ "$(cat "$log")" = "t1|rebase now" ] || fail "--execute did not dispatch the note verbatim to fm-send: $(cat "$log")"
  [ "$(field_of "$state" exec-note status)" = "done" ] || fail "--execute did not resolve the note done"
  pass "--execute dispatches a note to fm-send verbatim and resolves done"
}

test_execute_answer_revalidates_before_send() {
  local state fake log tok
  state=$(new_state)
  fake=$(make_fake_send "$state"); log="$state/send.log"
  printf 'window=x:fm-d\nkind=ship\n' > "$state/d.meta"
  printf 'needs-decision: A or B\n' > "$state/d.status"
  tok=$(lib_call "$state" fm_inbox_decision_token d)
  inbox_write "$state" exec-ans d answer "go A" "$tok"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null            # claim (token still current)
  # Gate MOVES between claim and execute.
  sleep 1; printf 'done: shipped\n' >> "$state/d.status"
  local rc; FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" FM_INBOX_SEND_BIN="$fake" "$DRAIN" --execute exec-ans; rc=$?
  [ "$rc" -eq 3 ] || fail "--execute of a moved-gate answer must reject with exit 3, got $rc"
  [ ! -s "$log" ] || fail "a rejected answer must NOT be sent: $(cat "$log")"
  [ "$(field_of "$state" exec-ans status)" = rejected ] || fail "the moved-gate answer must be resolved rejected"
  pass "--execute revalidates the decision token right before the send and refuses a moved gate"
}

test_execute_refuses_destructive() {
  local state fake log rc
  state=$(new_state)
  fake=$(make_fake_send "$state"); log="$state/send.log"
  printf 'window=x:fm-t2\nkind=ship\n' > "$state/t2.meta"
  inbox_write "$state" exec-merge t2 merge ""
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null            # claim
  FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" FM_INBOX_SEND_BIN="$fake" "$DRAIN" --execute exec-merge 2>/dev/null; rc=$?
  [ "$rc" -eq 2 ] || fail "--execute of a destructive action must refuse with exit 2, got $rc"
  [ ! -s "$log" ] || fail "a destructive action must never dispatch to a helper"
  [ "$(field_of "$state" exec-merge status)" = claimed ] || fail "a refused destructive action stays claimed for firstmate"
  pass "--execute refuses merge/teardown/interrupt (stays claimed for captain confirmation)"
}

test_execute_requires_claimed() {
  local state rc
  state=$(new_state)
  printf 'window=x:fm-t3\nkind=ship\n' > "$state/t3.meta"
  inbox_write "$state" exec-pend t3 note "x"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --execute exec-pend 2>/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "--execute of a not-yet-claimed intent must fail, got $rc"
  pass "--execute requires the intent to be claimed first"
}

# --- watcher inbox-wake path ------------------------------------------------

run_watch_once() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3; shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
  wait_for_exit "$!" 40
}

test_watcher_enqueues_inbox_wake() {
  local dir state fakebin out drain_out marker
  dir=$(make_case inbox-wake)
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  inbox_write "$state" wake-1 taskA note "please rebase"
  run_watch_once "$state" "$fakebin" "$out" || fail "watcher did not exit on a pending inbox intent"
  grep -F "inbox:" "$out" >/dev/null || fail "watcher did not print an inbox wake reason"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null || fail "wake drain failed"
  grep "$(printf '\tinbox\t')" "$drain_out" | grep -F "wake-1" >/dev/null || fail "inbox wake was not queued as an inbox record"
  marker=$(lib_call "$state" fm_inbox_seen_marker wake-1)
  [ -s "$marker" ] || fail "the collision-free seen marker was not written after the enqueue"
  pass "watcher enqueues a durable inbox wake for a new pending intent"
}

test_watcher_does_not_resurface_seen_intent() {
  local dir state fakebin out rc
  dir=$(make_case inbox-seen)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  inbox_write "$state" seen-1 taskA note "x"
  run_watch_once "$state" "$fakebin" "$out" || fail "first watcher run did not exit"
  grep -F "inbox:" "$out" >/dev/null || fail "first run did not surface the intent"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>/dev/null
  : > "$out"
  run_watch_once "$state" "$fakebin" "$out"; rc=$?
  if [ "$rc" -eq 0 ] && grep -F "inbox:" "$out" >/dev/null; then
    fail "an already-surfaced pending intent was re-enqueued (seen marker ignored)"
  fi
  pass "an already-surfaced pending intent is not re-enqueued"
}

# C1/N3: hostile inbox contents (oversized + malformed + spoof) must not crash or
# wedge the watcher, and the one valid pending intent must still surface.
test_watcher_survives_hostile_inbox() {
  local dir state fakebin out big
  dir=$(make_case inbox-hostile)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$state/captain-inbox"
  printf '{ broken' > "$state/captain-inbox/broken.json"
  head -c 64 /dev/urandom > "$state/captain-inbox/binary.json"
  big=$(head -c 20000 /dev/zero | tr '\0' 'x')
  jq -n --arg p "$big" '{intent_id:"big",ts:1,task_id:"t",action:"note",payload:$p,decision_id:"",version:"",status:"pending",result:""}' \
    > "$state/captain-inbox/big.json"
  inbox_write "$state" good-1 taskA note "handle me"
  run_watch_once "$state" "$fakebin" "$out" || fail "watcher did not exit with a valid pending intent among hostile files"
  grep -F "inbox:" "$out" >/dev/null || fail "watcher did not surface the one valid intent among hostile files"
  pass "watcher surfaces the valid intent and is not crashed/wedged by hostile inbox files"
}

test_watcher_inbox_poll_inert_without_dir() {
  local dir state fakebin out rc
  dir=$(make_case inbox-inert)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  [ ! -d "$state/captain-inbox" ] || fail "fixture unexpectedly has an inbox dir"
  run_watch_once "$state" "$fakebin" "$out"; rc=$?
  [ "$rc" -eq 124 ] || fail "watcher exited unexpectedly with no work to do (rc=$rc): $(cat "$out")"
  ! grep -F "inbox:" "$out" >/dev/null || fail "watcher printed an inbox wake with no inbox dir"
  pass "the inbox poll is inert with no inbox dir (existing paths undisturbed)"
}

test_idempotent_duplicate_write
test_concurrent_duplicate_write_no_clobber
test_invalid_action_task_and_id_rejected
test_oversized_payload_rejected
test_strict_schema_stem_spoof_rejected
test_malformed_file_skipped_and_noted
test_decision_token_changes_on_status_append
test_collision_free_seen_marker
test_drain_surfaces_and_claims_once
test_concurrent_drains_no_double_emit
test_drain_rejects_stale_answer
test_drain_surfaces_fresh_answer
test_resolve_terminal_only_no_regression
test_resolve_prunes_to_done_dir
test_crash_stranded_claim_resurfaced
test_list_and_show_readonly_and_find_done
test_execute_note_dispatches_via_send
test_execute_answer_revalidates_before_send
test_execute_refuses_destructive
test_execute_requires_claimed
test_watcher_enqueues_inbox_wake
test_watcher_does_not_resurface_seen_intent
test_watcher_survives_hostile_inbox
test_watcher_inbox_poll_inert_without_dir
