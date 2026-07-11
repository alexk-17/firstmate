#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Captain command inbox accessors, for the turn-start fallback below.
# shellcheck source=bin/fm-inbox-lib.sh
. "$SCRIPT_DIR/fm-inbox-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Turn-start fallback for the captain command inbox. The live path is the
# watcher's inbox poll, which enqueues an `inbox` wake when armed. But when no
# watcher is armed (an empty fleet, or before any task exists) nothing enqueues
# that wake, so surface any still-pending intent here too - the drain runs at the
# top of every wake-handling turn and at session start. It also flags a claim
# stranded past the reclaim window by a crash between claim and resolve, so a
# captain command can never sit invisibly. Printed to STDERR (like the guard
# banner) so it never pollutes the drained-record stdout stream. Gated on jq and
# on there actually being something to surface, so it is inert otherwise. MUST be
# called only AFTER the wake-queue lock is released (release_queue_lock below):
# its inbox scan must not run while a watcher's fm_wake_append blocks on the lock.
advise_inbox() {
  command -v jq >/dev/null 2>&1 || return 0
  if fm_inbox_has_pending; then
    printf 'INBOX: captain command(s) pending in the Dock inbox; run bin/fm-inbox-drain.sh to claim and execute.\n' >&2
  fi
  if fm_inbox_has_stranded_claims "${FM_INBOX_RECLAIM_SECS:-900}"; then
    printf 'INBOX: a claimed command looks stranded (unresolved past the reclaim window); run bin/fm-inbox-drain.sh to re-surface, or --show to inspect.\n' >&2
  fi
}

# Release the wake-queue lock exactly once, so the inbox scan in advise_inbox
# never holds it. The EXIT-trap cleanup then no-ops its own release.
release_queue_lock() {
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    DRAIN_LOCK_HELD=false
  fi
}

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  release_queue_lock
  advise_inbox
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
assert_watcher_liveness
release_queue_lock
advise_inbox
exit 0
