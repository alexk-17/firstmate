#!/usr/bin/env bash
# tests/fm-dock.test.sh - the Fleet Dock CONTROL console (bin/fm-dock.sh).
#
# The Dock only ever RENDERS read-only state and WRITES a captain intent into the
# durable inbox; it performs no backend action. These tests pin that write-side
# contract headlessly: the `submit` one-shot writes a validated intent stamped
# with its console provenance, an `answer` auto-stamps the decision token and
# requires a live decision gate, unknown tasks and malformed submissions are
# rejected, a trailing flag does NOT hang (the reproduced infinite loop), and the
# interactive loop writes on confirm, skips on cancel, and always exits cleanly.
#
# The full-screen TUI is layered strictly ON TOP of these paths. The regression
# tests at the end pin that the non-TUI surface is UNCHANGED: --plain forces the
# original picker, a non-tty invocation (default or --tui) falls back to the same
# picker and never hangs, and submit/status behave byte-for-byte as before.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

DOCK="$ROOT/bin/fm-dock.sh"
# Create the temp root directly in this shell (not via fm_test_tmproot, whose
# first call installs an EXIT trap that, fired inside a command-substitution
# subshell, would delete the dir - the gotcha documented in tests/wake-helpers.sh).
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-dock-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Each test passes a unique name (like make_case) so homes never collide.
new_home() {  # <name>
  local d="$TMP_ROOT/${1:?new_home needs a name}"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Register a live task (a meta, which the console's existence check requires) and
# an optional status line.
register_task() {  # <home> <task> [status-line]
  local home=$1 task=$2 status=${3:-}
  printf 'window=x:fm-%s\nkind=ship\n' "$task" > "$home/state/$task.meta"
  [ -n "$status" ] && printf '%s\n' "$status" > "$home/state/$task.status"
  return 0
}

# Run the Dock scoped to <home>, plain (no color), never on a real tty.
dock() {  # <home> <args...>
  local home=$1; shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" NO_COLOR=1 "$DOCK" "$@"
}

# Run a command under a perl watchdog (macOS has no `timeout`); exit 124 on hang.
run_bounded() {  # <secs> <cmd...>
  perl -e '
    my $s = shift; my $p = fork;
    if (!$p) { setpgrp(0,0); exec @ARGV; exit 127 }
    local $SIG{ALRM} = sub { kill "KILL", -$p; exit 124 };
    alarm $s; waitpid $p, 0; exit($? >> 8)' "$@"
}

json_count() {  # <dir>
  local n=0 f
  for f in "$1"/*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

only_intent() {  # <home>
  local d="$1/state/captain-inbox" f found=""
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    [ -z "$found" ] || fail "expected exactly one intent under $1, found more than one"
    found="$f"
  done
  [ -n "$found" ] || fail "expected exactly one intent under $1, found none"
  printf '%s' "$found"
}

test_submit_writes_intent() {
  local home f
  home=$(new_home submit-writes)
  register_task "$home" fix-login-k3
  dock "$home" submit --task fix-login-k3 --action note --payload "please rebase" >/dev/null \
    || fail "submit note failed"
  f=$(only_intent "$home")
  jq -e '.task_id == "fix-login-k3" and .action == "note" and .payload == "please rebase"
         and .status == "pending" and .version == "fm-dock" and (.intent_id | length > 0)' "$f" >/dev/null \
    || fail "submitted note intent has wrong fields: $(cat "$f")"
  pass "submit writes a correct pending note intent stamped with console provenance"
}

test_submit_answer_stamps_decision_token() {
  local home f tok
  home=$(new_home answer-token)
  register_task "$home" decide "needs-decision: A or B"
  dock "$home" submit --task decide --action answer --payload "go A" >/dev/null || fail "submit answer failed"
  f=$(only_intent "$home")
  tok=$(jq -r '.decision_id' "$f")
  [ -n "$tok" ] && [ "$tok" != null ] || fail "answer intent must auto-stamp a decision token, got '$tok'"
  pass "submit answer auto-stamps the current decision token"
}

test_submit_answer_requires_decision_gate() {
  local home rc
  home=$(new_home answer-no-gate)
  register_task "$home" busy "working: implementing"
  dock "$home" submit --task busy --action answer --payload "go A" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "answer to a task not awaiting a decision must be refused (exit 2), got $rc"
  [ ! -d "$home/state/captain-inbox" ] || [ "$(json_count "$home/state/captain-inbox")" = 0 ] \
    || fail "a refused answer must not write an intent"
  pass "submit answer requires the target to be awaiting a decision"
}

test_submit_rejects_unknown_task() {
  local home rc
  home=$(new_home unknown-task)
  dock "$home" submit --task ghost --action note --payload "x" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit for a task with no live meta must be refused (exit 2), got $rc"
  pass "submit rejects an unknown/torn-down task"
}

test_submit_rejects_bad_input() {
  local home rc
  home=$(new_home bad-input)
  register_task "$home" t1
  dock "$home" submit --task t1 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit without --action must exit 2, got $rc"
  dock "$home" submit --action note >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit without --task must exit 2, got $rc"
  dock "$home" submit --task t1 --action frobnicate >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit with an invalid action must exit 2, got $rc"
  dock "$home" submit --task t1 --action merge --payload "x" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit of a no-payload action with a payload must exit 2, got $rc"
  dock "$home" submit --task t1 --action note --payload "$(printf 'a\nb')" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit of a multiline note payload must exit 2, got $rc"
  [ ! -d "$home/state/captain-inbox" ] || [ "$(json_count "$home/state/captain-inbox")" = 0 ] \
    || fail "a rejected submit must not write an intent"
  pass "submit rejects missing task/action, invalid actions, and bad payloads"
}

# B4: a trailing flag (last arg is a flag with no value) must not spin forever.
test_submit_trailing_flag_no_hang() {
  local home rc args
  home=$(new_home trailing-flag)
  register_task "$home" t1
  for args in "--task" "--task t1 --action" "--task t1 --action note --payload"; do
    # shellcheck disable=SC2086
    run_bounded 5 env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" NO_COLOR=1 "$DOCK" submit $args >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 124 ] || fail "submit with trailing flag '$args' HUNG (infinite loop)"
    [ "$rc" -eq 2 ] || fail "submit with trailing flag '$args' should exit 2, got $rc"
  done
  pass "submit with a trailing flag rejects fast (no infinite loop)"
}

test_submit_explicit_intent_id_is_idempotent() {
  local home f
  home=$(new_home explicit-id)
  register_task "$home" t1
  dock "$home" submit --task t1 --action note --payload "one" --intent-id fixed-id >/dev/null
  dock "$home" submit --task t1 --action note --payload "two" --intent-id fixed-id >/dev/null
  f="$home/state/captain-inbox/fixed-id.json"
  [ "$(jq -r '.payload' "$f")" = "one" ] || fail "re-submitting the same intent-id must be a no-op"
  pass "submit --intent-id is idempotent on re-submit"
}

test_interactive_writes_on_confirm() {
  local home count
  home=$(new_home interactive-confirm)
  register_task "$home" fix-login-k3
  printf 'fix-login-k3\nnote\nrebase please\ny\nq\n' | dock "$home" >/dev/null 2>&1 \
    || fail "interactive dock exited non-zero"
  count=$(json_count "$home/state/captain-inbox")
  [ "$count" = 1 ] || fail "interactive confirm did not write exactly one intent (got $count)"
  jq -e '.action == "note" and .task_id == "fix-login-k3" and .payload == "rebase please"' \
    "$home/state/captain-inbox"/*.json >/dev/null || fail "interactive intent has wrong fields"
  pass "interactive loop writes an intent on confirm"
}

test_interactive_cancel_writes_nothing() {
  local home
  home=$(new_home interactive-cancel)
  register_task "$home" fix-login-k3
  printf 'fix-login-k3\nnote\nrebase please\nn\nq\n' | dock "$home" >/dev/null 2>&1 \
    || fail "interactive dock exited non-zero on cancel"
  [ ! -d "$home/state/captain-inbox" ] || [ "$(json_count "$home/state/captain-inbox")" = 0 ] \
    || fail "a cancelled interactive submission must write no intent"
  pass "interactive loop writes nothing when the captain cancels"
}

test_interactive_exits_on_eof() {
  local home rc
  home=$(new_home interactive-eof)
  printf '' | dock "$home" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "interactive dock must exit 0 on immediate EOF, got $rc"
  pass "interactive loop exits cleanly on EOF (never hangs)"
}

test_help_and_status_are_readonly() {
  local home
  home=$(new_home help-status)
  dock "$home" --help | grep -F "Fleet Dock" >/dev/null || fail "--help did not render usage"
  dock "$home" status | grep -F "NEEDS YOU" >/dev/null || fail "status did not render the digest"
  [ ! -d "$home/state/captain-inbox" ] || [ "$(json_count "$home/state/captain-inbox")" = 0 ] \
    || fail "status/help must not write any intent"
  pass "--help and status are read-only"
}

# --- additive-layer regression guard ---------------------------------------
# The TUI must not change any non-TUI behavior. These prove the default/forced
# non-tty surface is exactly the original picker.

test_plain_flag_uses_picker() {
  local home count
  home=$(new_home plain-picker)
  register_task "$home" fix-login-k3
  printf 'fix-login-k3\nnote\nrebase please\ny\nq\n' | dock "$home" --plain >/dev/null 2>&1 \
    || fail "--plain picker exited non-zero"
  count=$(json_count "$home/state/captain-inbox")
  [ "$count" = 1 ] || fail "--plain must drive the original picker (expected 1 intent, got $count)"
  jq -e '.action == "note" and .task_id == "fix-login-k3" and .payload == "rebase please"' \
    "$home/state/captain-inbox"/*.json >/dev/null || fail "--plain picker intent has wrong fields"
  pass "--plain forces the original picker loop unchanged"
}

test_default_nontty_uses_picker() {
  local home count
  home=$(new_home default-nontty)
  register_task "$home" fix-login-k3
  # No subcommand, piped (non-tty) stdin: must fall to the picker, not the TUI.
  printf 'fix-login-k3\nnote\nrebase please\ny\nq\n' | dock "$home" >/dev/null 2>&1 \
    || fail "default non-tty dock exited non-zero"
  count=$(json_count "$home/state/captain-inbox")
  [ "$count" = 1 ] || fail "default on a non-tty must use the picker (expected 1 intent, got $count)"
  pass "default interactive on a non-tty is the picker, byte-for-byte as before"
}

test_tui_flag_falls_back_when_no_tty() {
  local home count rc
  home=$(new_home tui-fallback)
  register_task "$home" fix-login-k3
  # --tui with no real tty must degrade to the picker AND never hang.
  run_bounded 5 bash -c '
    printf "fix-login-k3\nnote\nrebase please\ny\nq\n" \
      | env FM_HOME="'"$home"'" FM_STATE_OVERRIDE="'"$home"'/state" NO_COLOR=1 "'"$DOCK"'" --tui >/dev/null 2>&1'
  rc=$?
  [ "$rc" -ne 124 ] || fail "--tui without a tty HUNG instead of falling back"
  count=$(json_count "$home/state/captain-inbox")
  [ "$count" = 1 ] || fail "--tui without a tty must fall back to the picker (expected 1 intent, got $count)"
  pass "--tui degrades to the picker without a tty and never hangs"
}

test_status_output_unchanged() {
  local home out
  home=$(new_home status-unchanged)
  register_task "$home" fix-login-k3 "working: implementing"
  # status still renders the read-only digest and writes nothing - the sourcing
  # of the TUI lib must not perturb it.
  out=$(dock "$home" status) || fail "status exited non-zero"
  assert_contains "$out" "NEEDS YOU" "status must still render the fleet digest"
  assert_contains "$out" "RUNNING" "status must still render every digest section"
  [ ! -d "$home/state/captain-inbox" ] || [ "$(json_count "$home/state/captain-inbox")" = 0 ] \
    || fail "status must remain read-only under the TUI layer"
  pass "status subcommand output is unchanged and read-only under the TUI layer"
}

test_submit_writes_intent
test_submit_answer_stamps_decision_token
test_submit_answer_requires_decision_gate
test_submit_rejects_unknown_task
test_submit_rejects_bad_input
test_submit_trailing_flag_no_hang
test_submit_explicit_intent_id_is_idempotent
test_interactive_writes_on_confirm
test_interactive_cancel_writes_nothing
test_interactive_exits_on_eof
test_help_and_status_are_readonly
test_plain_flag_uses_picker
test_default_nontty_uses_picker
test_tui_flag_falls_back_when_no_tty
test_status_output_unchanged
