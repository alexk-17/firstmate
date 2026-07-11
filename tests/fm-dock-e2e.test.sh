#!/usr/bin/env bash
# tests/fm-dock-e2e.test.sh - end-to-end demo of the Fleet Dock control loop.
#
# A human can run this directly (`bash tests/fm-dock-e2e.test.sh`) to WATCH the
# captain-command round-trip, and it asserts each step so it doubles as a CI
# guard on the full wiring. It proves the loop WITHOUT a live crewmate:
#
#   1. fm-dock.sh writes a `note` intent for a (fake) in-flight task
#   2. the watcher notices the pending intent and surfaces an `inbox` wake
#   3. fm-wake-drain.sh shows the durable inbox record firstmate would wake on
#   4. fm-inbox-drain.sh surfaces one actionable record and claims the intent
#   5. firstmate would now execute it via the EXISTING helper (fm-send for a
#      note) - simulated here, because the point is the control plane, not a
#      real crewmate - then records the outcome with --resolve
#   6. the Dock reflects the intent as done
#
# The console never touched a crewmate: it only wrote an intent, and firstmate
# (here, this script standing in for it) is the sole executor.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

DOCK="$ROOT/bin/fm-dock.sh"
INBOX_DRAIN="$ROOT/bin/fm-inbox-drain.sh"
WAKE_DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-dock-e2e)

say() { printf '\n>>> %s\n' "$1"; }

dir=$(make_case dock-e2e)
state="$dir/state"
fakebin="$dir/fakebin"
export FM_HOME="$dir" FM_STATE_OVERRIDE="$state"

# A fake in-flight task the note targets (a meta + a status line), so the round
# trip mirrors a real ship task without spawning anything.
TASK="fix-login-k3"
printf 'window=dock-e2e:fm-%s\nkind=ship\n' "$TASK" > "$state/$TASK.meta"
printf 'working: implementing\n' > "$state/$TASK.status"

say "STEP 1 - captain submits a note via the Dock console (write-only)"
out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" NO_COLOR=1 "$DOCK" submit \
        --task "$TASK" --action note --payload "please rebase onto main before CI")
printf '    %s\n' "$out"
iid=$(printf '%s' "$out" | sed -E 's/^queued intent ([^ ]+).*/\1/')
[ -n "$iid" ] || fail "e2e: could not read the queued intent id"
[ "$(jq -r '.status' "$state/captain-inbox/$iid.json")" = pending ] \
  || fail "e2e: the submitted intent should start pending"

say "STEP 2 - the watcher notices the pending intent and surfaces an inbox wake"
watch_out="$dir/watch.out"
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$watch_out" &
wait_for_exit "$!" 40 || fail "e2e: watcher did not exit on the pending intent"
grep -F "inbox:" "$watch_out" >/dev/null || fail "e2e: watcher did not surface an inbox wake"
printf '    watcher woke: %s\n' "$(cat "$watch_out")"

say "STEP 3 - fm-wake-drain.sh shows the durable inbox record firstmate wakes on"
wake_out=$(FM_STATE_OVERRIDE="$state" "$WAKE_DRAIN" 2>/dev/null)
printf '    %s\n' "$wake_out"
printf '%s' "$wake_out" | grep "$(printf '\tinbox\t')" | grep -F "$iid" >/dev/null \
  || fail "e2e: the inbox wake was not queued as a durable record"

say "STEP 4 - fm-inbox-drain.sh surfaces one actionable record and claims it"
record=$(FM_STATE_OVERRIDE="$state" "$INBOX_DRAIN")
printf '    %s\n' "$record"
printf '%s' "$record" | jq -e --arg id "$iid" '.intent_id == $id and .action == "note"' >/dev/null \
  || fail "e2e: drain did not surface the actionable note record"
[ "$(jq -r '.status' "$state/captain-inbox/$iid.json")" = claimed ] \
  || fail "e2e: drain did not claim the intent"

say "STEP 5 - firstmate executes it via the existing helper (fm-send), then resolves"
task_id=$(printf '%s' "$record" | jq -r '.task_id')
payload=$(printf '%s' "$record" | jq -r '.payload')
printf "    (firstmate would run: FM_HOME=%s bin/fm-send.sh %s '%s')\n" "$dir" "$task_id" "$payload"
FM_STATE_OVERRIDE="$state" "$INBOX_DRAIN" --resolve "$iid" "done" "note relayed to $task_id via fm-send"

say "STEP 6 - the Dock reflects the intent as done"
FM_STATE_OVERRIDE="$state" "$INBOX_DRAIN" --show "$iid" | jq -c '{intent_id, status, result}'
[ "$(jq -r '.status' "$state/captain-inbox/$iid.json")" = "done" ] \
  || fail "e2e: the intent was not marked done after resolve"

say "STEP 7 - no pending intents remain"
[ -z "$(FM_STATE_OVERRIDE="$state" "$INBOX_DRAIN" --list)" ] \
  || fail "e2e: an intent is still pending after the round-trip"

pass "e2e round-trip: dock -> watcher inbox wake -> drain/claim -> resolve -> done"
