#!/usr/bin/env bash
# tests/fm-dock.test.sh - the Fleet Dock CONTROL console (bin/fm-dock.sh).
#
# The Dock only ever RENDERS read-only state and WRITES a captain intent into the
# durable inbox; it performs no backend action. These tests pin that write-side
# contract headlessly: the `submit` one-shot writes a correct intent, an `answer`
# auto-stamps the decision token (staleness guard) unless suppressed, bad input
# is rejected, and the interactive loop driven by scripted stdin writes on
# confirm, skips on cancel, and always exits cleanly (never hangs).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

DOCK="$ROOT/bin/fm-dock.sh"
# Create the temp root directly in this shell (not via fm_test_tmproot, whose
# first call installs an EXIT trap that, fired inside a command-substitution
# subshell, would delete the dir on subshell exit - the gotcha documented in
# tests/wake-helpers.sh). Register our own cleanup.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-dock-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Each test passes a unique name (like make_case) so homes never collide - a bare
# counter would not survive the command-substitution subshell new_home runs in.
new_home() {  # <name>
  local d="$TMP_ROOT/${1:?new_home needs a name}"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Run the Dock scoped to <home>, plain (no color), never on a real tty.
dock() {  # <home> <args...>
  local home=$1; shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" NO_COLOR=1 "$DOCK" "$@"
}

json_count() {  # <dir>
  local n=0 f
  for f in "$1"/*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# Echo the single intent JSON file under <home> (fails the test if not exactly one).
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
  dock "$home" submit --task fix-login-k3 --action note --payload "please rebase" >/dev/null \
    || fail "submit note failed"
  f=$(only_intent "$home")
  jq -e '.task_id == "fix-login-k3" and .action == "note" and .payload == "please rebase"
         and .status == "pending" and (.intent_id | length > 0)' "$f" >/dev/null \
    || fail "submitted note intent has wrong fields: $(cat "$f")"
  pass "submit writes a correct pending note intent"
}

test_submit_answer_stamps_decision_token() {
  local home f tok
  home=$(new_home answer-token)
  printf 'needs-decision: A or B\n' > "$home/state/decide.status"
  dock "$home" submit --task decide --action answer --payload "go A" >/dev/null || fail "submit answer failed"
  f=$(only_intent "$home")
  tok=$(jq -r '.decision_id' "$f")
  [ -n "$tok" ] && [ "$tok" != null ] || fail "answer intent must auto-stamp a decision token, got '$tok'"
  pass "submit answer auto-stamps the current decision token"
}

test_submit_answer_no_decision_flag() {
  local home f
  home=$(new_home answer-nodecision)
  printf 'needs-decision: A or B\n' > "$home/state/decide.status"
  dock "$home" submit --task decide --action answer --payload "go A" --no-decision >/dev/null \
    || fail "submit answer --no-decision failed"
  f=$(only_intent "$home")
  [ "$(jq -r '.decision_id' "$f")" = "" ] || fail "--no-decision must leave the decision token empty"
  pass "submit --no-decision suppresses the staleness token"
}

test_submit_explicit_intent_id_is_idempotent() {
  local home f
  home=$(new_home explicit-id)
  dock "$home" submit --task t1 --action note --payload "one" --intent-id fixed-id >/dev/null
  dock "$home" submit --task t1 --action note --payload "two" --intent-id fixed-id >/dev/null
  f="$home/state/captain-inbox/fixed-id.json"
  [ "$(jq -r '.payload' "$f")" = "one" ] || fail "re-submitting the same intent-id must be a no-op"
  pass "submit --intent-id is idempotent on re-submit"
}

test_submit_rejects_bad_input() {
  local home rc
  home=$(new_home bad-input)
  dock "$home" submit --task t1 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit without --action must exit 2, got $rc"
  dock "$home" submit --action note >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit without --task must exit 2, got $rc"
  dock "$home" submit --task t1 --action frobnicate >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "submit with an invalid action must exit 2, got $rc"
  [ ! -d "$home/state/captain-inbox" ] || [ -z "$(ls -A "$home/state/captain-inbox" 2>/dev/null)" ] \
    || fail "a rejected submit must not write an intent"
  pass "submit rejects missing task/action and invalid actions"
}

test_interactive_writes_on_confirm() {
  local home count
  home=$(new_home interactive-confirm)
  # task, action, payload, confirm (y), then quit.
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
  # Answer 'n' to the confirm: nothing should be written.
  printf 'fix-login-k3\nnote\nrebase please\nn\nq\n' | dock "$home" >/dev/null 2>&1 \
    || fail "interactive dock exited non-zero on cancel"
  [ -z "$(ls -A "$home/state/captain-inbox" 2>/dev/null)" ] \
    || fail "a cancelled interactive submission must write no intent"
  pass "interactive loop writes nothing when the captain cancels"
}

test_interactive_exits_on_eof() {
  local home rc
  home=$(new_home interactive-eof)
  # Empty stdin (immediate EOF): the loop must exit cleanly, not hang.
  printf '' | dock "$home" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "interactive dock must exit 0 on immediate EOF, got $rc"
  pass "interactive loop exits cleanly on EOF (never hangs)"
}

test_help_and_status_are_readonly() {
  local home
  home=$(new_home help-status)
  dock "$home" --help | grep -F "Fleet Dock" >/dev/null || fail "--help did not render usage"
  dock "$home" status | grep -F "NEEDS YOU" >/dev/null || fail "status did not render the digest"
  [ -z "$(ls -A "$home/state/captain-inbox" 2>/dev/null)" ] \
    || fail "status/help must not write any intent"
  pass "--help and status are read-only"
}

test_submit_writes_intent
test_submit_answer_stamps_decision_token
test_submit_answer_no_decision_flag
test_submit_explicit_intent_id_is_idempotent
test_submit_rejects_bad_input
test_interactive_writes_on_confirm
test_interactive_cancel_writes_nothing
test_interactive_exits_on_eof
test_help_and_status_are_readonly
