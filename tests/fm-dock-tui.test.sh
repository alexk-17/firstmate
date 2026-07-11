#!/usr/bin/env bash
# tests/fm-dock-tui.test.sh - the PURE core of the Fleet Dock full-screen TUI
# (bin/fm-dock-tui-lib.sh).
#
# The TUI's fragile part (raw-mode input, alt-screen, escape sequences) is
# deliberately untested; its value comes from keeping everything the captain sees
# and every key->intent decision in PURE functions that ARE tested here. These
# pin: the selection state machine (actionable order matches the fleet-status
# projection, clamping and no-wrap movement), the key->action dispatch and its
# payload/destructive gates, and the exact rendered screen for the list and
# detail views - including color on/off, the cursor marker landing on the right
# row, health glyphs, the inbox strip, a flash line, and the decision card.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=bin/fm-dock-tui-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-dock-tui-lib.sh"

# A projection fixture shaped exactly like fm-fleet-status.sh --json: one row in
# each actionable section plus a recently-done row.
SJSON='{
  "fm_home":"/tmp/home",
  "sections":{
    "needs_you":[{"id":"decide-a1","health":"idle","phase":"needs-decision","owner":"captain","freshness":{"age":"2m"},"next_action":"your decision","headline":"A or B"}],
    "at_risk":[{"id":"stale-b2","health":"stale","phase":"working","owner":"crew","freshness":{"age":"9m"},"next_action":"stopped mid-work?","headline":"impl"}],
    "running":[{"id":"run-c3","health":"active","phase":"validating","owner":"ci","freshness":{"age":"30s"},"next_action":"checks / CI","headline":"ci"}],
    "recently_done":[{"id":"done-d4","title":"fixed the thing","repo":"alpha","artifact":"pr#1"}]
  }
}'
EMPTY='{"fm_home":"/tmp/home","sections":{"needs_you":[],"at_risk":[],"running":[],"recently_done":[]}}'

test_actionable_order_and_count() {
  local ids
  ids=$(fm_dock_actionable_ids "$SJSON")
  [ "$ids" = "$(printf 'decide-a1\nstale-b2\nrun-c3')" ] \
    || fail "actionable ids must be needs_you, at_risk, running in order, got: $ids"
  [ "$(fm_dock_actionable_count "$SJSON")" = 3 ] || fail "actionable count must be 3"
  [ "$(fm_dock_actionable_count "$EMPTY")" = 0 ] || fail "empty projection must count 0"
  [ "$(fm_dock_nth_id "$SJSON" 1)" = stale-b2 ] || fail "nth_id 1 must be stale-b2"
  [ -z "$(fm_dock_nth_id "$SJSON" 9)" ] || fail "nth_id out of range must be empty"
  pass "actionable list order, count, and nth match the fleet-status projection"
}

test_selection_clamp_and_move() {
  [ "$(fm_dock_clamp_sel 9 3)" = 2 ] || fail "clamp above range -> last index"
  [ "$(fm_dock_clamp_sel -1 3)" = 0 ] || fail "clamp below range -> 0"
  [ "$(fm_dock_clamp_sel 1 0)" = 0 ] || fail "clamp with empty list -> 0"
  [ "$(fm_dock_move_sel 0 3 up)" = 0 ] || fail "up at top stays 0 (no wrap)"
  [ "$(fm_dock_move_sel 2 3 down)" = 2 ] || fail "down at bottom stays last (no wrap)"
  [ "$(fm_dock_move_sel 0 3 down)" = 1 ] || fail "down within range moves +1"
  [ "$(fm_dock_move_sel 2 3 up)" = 1 ] || fail "up within range moves -1"
  [ "$(fm_dock_move_sel 0 0 down)" = 0 ] || fail "move on empty list stays 0"
  pass "selection clamps into range and moves without wrapping"
}

test_key_to_action_dispatch() {
  [ "$(fm_dock_action_for_key a)" = answer ] || fail "a -> answer"
  [ "$(fm_dock_action_for_key n)" = note ] || fail "n -> note"
  [ "$(fm_dock_action_for_key m)" = merge ] || fail "m -> merge"
  [ "$(fm_dock_action_for_key p)" = peek ] || fail "p -> peek"
  [ "$(fm_dock_action_for_key i)" = interrupt ] || fail "i -> interrupt"
  [ "$(fm_dock_action_for_key t)" = teardown ] || fail "t -> teardown"
  [ -z "$(fm_dock_action_for_key z)" ] || fail "unknown key -> empty"
  fm_dock_action_needs_payload answer || fail "answer needs a payload"
  fm_dock_action_needs_payload note || fail "note needs a payload"
  ! fm_dock_action_needs_payload merge || fail "merge needs no payload"
  fm_dock_action_is_destructive merge || fail "merge is destructive"
  fm_dock_action_is_destructive teardown || fail "teardown is destructive"
  fm_dock_action_is_destructive interrupt || fail "interrupt is destructive"
  ! fm_dock_action_is_destructive note || fail "note is not destructive"
  ! fm_dock_action_is_destructive peek || fail "peek is not destructive"
  pass "key->action mapping and payload/destructive gates match the inbox actions"
}

test_render_list_structure_and_plain() {
  local out
  out=$(fm_dock_render_list "$SJSON" 1 80 40 false "12:00:00" 3 '[]' '')
  assert_contains "$out" "Fleet Dock" "list must render the header"
  assert_contains "$out" "/tmp/home" "list header shows the fleet home"
  assert_contains "$out" "⟳3s" "list header shows the refresh cadence"
  assert_contains "$out" "NEEDS YOU  (1)" "list renders the NEEDS YOU section with a count"
  assert_contains "$out" "AT RISK  (1)" "list renders the AT RISK section"
  assert_contains "$out" "RUNNING  (1)" "list renders the RUNNING section"
  assert_contains "$out" "RECENTLY DONE  (1)" "list renders the RECENTLY DONE section"
  assert_contains "$out" "decide-a1" "list shows the needs-you task id"
  assert_contains "$out" "done-d4" "list shows the recently-done id"
  assert_contains "$out" "▲" "stale health uses its glyph"
  assert_contains "$out" "●" "active health uses its glyph"
  assert_contains "$out" "○" "idle health uses its glyph"
  assert_contains "$out" "a answer" "footer shows the keymap"
  assert_contains "$out" "q quit" "footer keymap is not clipped at the default 80-col width"
  # sel=1 -> the cursor marks stale-b2, not decide-a1.
  assert_contains "$out" "› stale-b2" "the cursor marker lands on the selected row"
  assert_not_contains "$out" "› decide-a1" "unselected rows carry no cursor marker"
  # plain output carries no ANSI escapes.
  assert_not_contains "$out" "$(printf '\033')" "NO_COLOR/plain render must contain no ANSI escapes"
  pass "list render is complete and fully plain when color is off"
}

test_render_list_color_and_flash_and_inbox() {
  local out inbox
  out=$(fm_dock_render_list "$SJSON" 0 80 40 true "12:00:00" 3 '[]' '')
  assert_contains "$out" "$(printf '\033')" "color render must contain ANSI escapes"
  inbox='[{"intent_id":"i1","task_id":"decide-a1","action":"note","status":"pending","ts":5}]'
  out=$(fm_dock_render_list "$SJSON" 0 80 40 false "12:00:00" 3 "$inbox" "queued: note decide-a1")
  assert_contains "$out" "inbox: note/decide-a1" "inbox strip shows the captain's recent intent"
  assert_contains "$out" "» queued: note decide-a1" "a flash line renders when set"
  out=$(fm_dock_render_list "$SJSON" 0 80 40 false "12:00:00" 3 '[]' '')
  assert_contains "$out" "inbox: (empty)" "empty inbox renders an explicit empty marker"
  assert_not_contains "$out" "» " "no flash line renders when the flash is empty"
  pass "color, flash, and inbox strip render correctly"
}

test_render_list_empty_is_safe() {
  local out
  out=$(fm_dock_render_list "$EMPTY" 0 80 40 false "12:00:00" 3 '[]' '') \
    || fail "rendering an empty projection must not error"
  assert_contains "$out" "Nothing needs you." "empty needs-you shows its note"
  assert_contains "$out" "No tasks in flight." "empty running shows its note"
  assert_contains "$out" "No recently completed work." "empty done shows its note"
  pass "an all-empty projection renders safely with per-section empty notes"
}

test_render_detail() {
  local out djson
  djson='{"id":"decide-a1","project":"alpha","harness":"claude","mode":"no-mistakes","kind":"ship","phase":"needs-decision","owner":"captain","health":"idle","age":"2m","pr_url":null,"branch":"fm/decide-a1","crew_state":"state: parked","decision":{"present":true,"text":"needs-decision: A or B"},"status_tail":["working: start","needs-decision: A or B"]}'
  out=$(fm_dock_render_detail "$djson" 80 40 false)
  assert_contains "$out" "Task decide-a1" "detail titles the task"
  assert_contains "$out" "project   alpha" "detail shows the project"
  assert_contains "$out" "harness   claude" "detail shows the harness"
  assert_contains "$out" "mode      no-mistakes" "detail shows the delivery mode"
  assert_contains "$out" "branch    fm/decide-a1" "detail shows the branch"
  assert_contains "$out" "state     needs-decision" "detail shows the reduced state"
  assert_contains "$out" "DECISION NEEDED" "an awaiting-decision task shows the decision card"
  assert_contains "$out" "needs-decision: A or B" "the decision text/options render inline"
  assert_contains "$out" "working: start" "the recent-status tail renders"
  assert_not_contains "$out" "$(printf '\033')" "plain detail render carries no ANSI escapes"
  pass "detail view renders identity, state, decision, and status tail"
}

test_render_detail_no_decision() {
  local out djson
  djson='{"id":"run-c3","project":"alpha","harness":"codex","mode":"direct-PR","kind":"ship","phase":"validating","owner":"ci","health":"active","age":"30s","pr_url":"https://example/pr/9","branch":"-","crew_state":"","decision":{"present":false,"text":""},"status_tail":[]}'
  out=$(fm_dock_render_detail "$djson" 80 40 false)
  assert_not_contains "$out" "DECISION NEEDED" "a task not awaiting a decision shows no decision card"
  assert_contains "$out" "pr        https://example/pr/9" "detail shows a PR url when present"
  assert_contains "$out" "(none)" "an empty status tail renders an explicit marker"
  pass "detail view omits the decision card and shows the PR url when there is no gate"
}

test_render_list_width_clip() {
  command -v python3 >/dev/null 2>&1 || { pass "width-clip check skipped (python3 absent)"; return 0; }
  local out mv
  # Plain, width 20: no physical line may exceed 20 codepoints.
  out=$(fm_dock_render_list "$SJSON" 1 20 24 false "12:00:00" 3 '[]' 'a very long flash that must be clipped hard')
  mv=$(printf '%s\n' "$out" | python3 -c 'import sys; print(max((len(l.rstrip(chr(10))) for l in sys.stdin), default=0))')
  [ "$mv" -le 20 ] || fail "plain lines must clip to width 20, got max $mv"
  # Color, width 20: the VISIBLE width (ANSI stripped) must still be <= 20, and a
  # line must never be cut mid-escape.
  out=$(fm_dock_render_list "$SJSON" 1 20 24 true "12:00:00" 3 '[]' '')
  mv=$(printf '%s\n' "$out" | python3 -c 'import sys,re; print(max((len(re.sub(chr(27)+r"\[[0-9;]*m","",l.rstrip(chr(10)))) for l in sys.stdin), default=0))')
  [ "$mv" -le 20 ] || fail "colored lines must clip to VISIBLE width 20, got max $mv"
  pass "every rendered line is clipped to the terminal width (plain and colored)"
}

test_render_list_viewport() {
  command -v python3 >/dev/null 2>&1 || { pass "viewport check skipped (python3 absent)"; return 0; }
  local big out nlines
  big=$(python3 -c 'import json; print(json.dumps({"fm_home":"/h","sections":{"needs_you":[],"at_risk":[],"running":[{"id":"t%02d"%i,"health":"active","phase":"working","owner":"crew","freshness":{"age":"1m"},"next_action":"x","headline":"h"} for i in range(30)],"recently_done":[]}}))')
  # 30 tasks, selection deep in the list, a 10-row terminal.
  out=$(fm_dock_render_list "$big" 25 80 10 false "12:00" 3 '[]' '')
  nlines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$nlines" -le 10 ] || fail "viewport must bound output to rows=10, got $nlines lines"
  assert_contains "$out" "› t25" "the selected row stays inside the scrolled viewport"
  assert_contains "$out" "q quit" "the footer keymap stays visible while scrolling"
  pass "the list is bounded to a viewport that keeps the selection and footer visible"
}

test_actionable_order_and_count
test_selection_clamp_and_move
test_key_to_action_dispatch
test_render_list_structure_and_plain
test_render_list_color_and_flash_and_inbox
test_render_list_empty_is_safe
test_render_list_width_clip
test_render_list_viewport
test_render_detail
test_render_detail_no_decision
