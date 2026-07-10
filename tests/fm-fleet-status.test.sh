#!/usr/bin/env bash
# Behavior tests for the prioritized fleet-status reducer.
#
# fm-fleet-status.sh reduces bin/fm-fleet-snapshot.sh --json into four
# owner-bucketed sections. These tests pin the classification contract:
# section bucketing by attention owner, reconciliation over a stale status-log
# line (current state wins, never the last log verb), the empty fleet, and a
# task whose current state cannot be resolved (unknown, never guessed).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS="$ROOT/bin/fm-fleet-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-status)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# Pin "now" so freshness ages are reproducible across runs.
NOW=2000000000

# A fakebin whose no-mistakes reports no run (so fm-crew-state falls back to the
# pane, then the status log) and whose tmux marks a window busy only when its
# target name contains "busy". That busy trigger is how a test forces a
# reconciled `working` current state that overrides a stale status-log verb.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *busy*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# run_json <home> <fakebin> -> the --json projection
run_json() {  # <home> <fakebin>
  PATH="$2:$PATH" FM_HOME="$1" FM_FLEET_STATUS_NOW="$NOW" "$STATUS" --json
}

test_empty_fleet() {
  local home out human
  home=$(make_home empty)
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] shipped - Shipped Thing - https://github.com/kunchenguid/firstmate/pull/3 (repo: alpha, merged 2026-07-02) (kind: ship)
EOF
  out=$(FM_HOME="$home" FM_FLEET_STATUS_NOW="$NOW" "$STATUS" --json) \
    || fail "empty-fleet --json must exit 0"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-status.v1"
      and (.sections.needs_you | length) == 0
      and (.sections.at_risk | length) == 0
      and (.sections.running | length) == 0
      and (.sections.recently_done | length) == 1
      and .sections.recently_done[0].id == "shipped"
  ' >/dev/null || fail "empty fleet projection wrong: $out"
  human=$(FM_HOME="$home" FM_FLEET_STATUS_NOW="$NOW" "$STATUS") \
    || fail "empty-fleet human must exit 0"
  assert_contains "$human" "No tasks in flight." "empty fleet should say no tasks in flight"
  assert_contains "$human" "RECENTLY DONE" "empty fleet should still show recently done"
  assert_contains "$human" "shipped" "empty fleet should list the done record"
  pass "empty fleet: no in-flight tasks, recently-done still shown, exit 0"
}

test_section_bucketing_by_owner() {
  local home fakebin out human
  home=$(make_home buckets)
  mkdir -p \
    "$home/projects/dec" "$home/projects/pr" "$home/projects/local" \
    "$home/projects/scout" "$home/projects/broke" "$home/projects/block" \
    "$home/projects/coding-busy" "$home/projects/pause" "$home/data/scout-task"
  # NEEDS YOU: a captain decision (idle pane keeps the needs-decision current).
  fm_write_meta "$home/state/dec-task.meta" \
    "window=firstmate:fm-dec-task" "worktree=$home/projects/dec" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'needs-decision: REST or GraphQL\n' > "$home/state/dec-task.status"
  # NEEDS YOU: a PR ready to merge.
  fm_write_meta "$home/state/pr-task.meta" \
    "window=firstmate:fm-pr-task" "worktree=$home/projects/pr" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/99"
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/99 checks green\n' > "$home/state/pr-task.status"
  # NEEDS YOU: a local-only branch ready for review + approval.
  fm_write_meta "$home/state/local-task.meta" \
    "window=firstmate:fm-local-task" "worktree=$home/projects/local" \
    "project=beta" "harness=codex" "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready in branch fm/local-task\n' > "$home/state/local-task.status"
  # NEEDS YOU: a scout report ready for the captain. mode=local-only is a real
  # delivery mode fm-spawn records (a scout inherits its project's mode); it must
  # still route to the report, never to the local-only "review diff, then approve".
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" "worktree=$home/projects/scout" \
    "project=alpha" "harness=codex" "kind=scout" "mode=local-only" "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  printf '# findings\n' > "$home/data/scout-task/report.md"
  # AT RISK: a failed run.
  fm_write_meta "$home/state/broke-task.meta" \
    "window=firstmate:fm-broke-task" "worktree=$home/projects/broke" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'failed: build will not compile\n' > "$home/state/broke-task.status"
  # AT RISK: a genuinely blocked crew.
  fm_write_meta "$home/state/block-task.meta" \
    "window=firstmate:fm-block-task" "worktree=$home/projects/block" \
    "project=beta" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'blocked: waiting on prod credentials\n' > "$home/state/block-task.status"
  # RUNNING: a crew actively coding (busy pane).
  fm_write_meta "$home/state/coding-task.meta" \
    "window=firstmate:fm-coding-busy" "worktree=$home/projects/coding-busy" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: implementing the endpoint\n' > "$home/state/coding-task.status"
  # RUNNING: a declared external wait.
  fm_write_meta "$home/state/pause-task.meta" \
    "window=firstmate:fm-pause-task" "worktree=$home/projects/pause" \
    "project=gamma" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'paused: waiting on upstream release cut\n' > "$home/state/pause-task.status"

  fakebin=$(make_fakebin "$home")
  out=$(run_json "$home" "$fakebin") || fail "bucketing --json must exit 0"

  printf '%s' "$out" | jq -e '
    def ids($s): [$s[].id] | sort;
    (ids(.sections.needs_you) == ["dec-task","local-task","pr-task","scout-task"])
      and (ids(.sections.at_risk) == ["block-task","broke-task"])
      and (ids(.sections.running) == ["coding-task","pause-task"])
  ' >/dev/null || fail "owner bucketing wrong: $(printf '%s' "$out" | jq -c '.sections | map_values(map(.id))')"

  # Dimensions must stay separated, not conflated.
  printf '%s' "$out" | jq -e '
    def row($id): (.sections.needs_you + .sections.at_risk + .sections.running)[] | select(.id == $id);
    (row("dec-task")   | .phase == "needs-decision" and .owner == "captain" and .reply_syntax == "dec-task: <your decision>")
      and (row("pr-task")    | .phase == "ready" and .owner == "captain" and .reply_syntax == "https://github.com/kunchenguid/firstmate/pull/99")
      and (row("local-task") | .phase == "ready" and .owner == "captain" and .reply_syntax == "local-task: approve")
      and (row("scout-task") | .phase == "done" and .owner == "captain" and .next_action == "findings ready - read report" and (.reply_syntax | endswith("scout-task/report.md")))
      and (row("broke-task") | .phase == "failed" and .owner == "firstmate")
      and (row("block-task") | .phase == "blocked" and .owner == "firstmate")
      and (row("coding-task")| .phase == "working" and .owner == "crew" and .health == "active")
      and (row("pause-task") | .phase == "paused" and .owner == "external")
  ' >/dev/null || fail "phase/owner/health separation wrong: $out"

  human=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FLEET_STATUS_NOW="$NOW" "$STATUS") \
    || fail "bucketing human must exit 0"
  assert_contains "$human" "reply: dec-task: <your decision>" "NEEDS YOU should print the decision reply syntax"
  assert_contains "$human" "reply: https://github.com/kunchenguid/firstmate/pull/99" "NEEDS YOU should print the PR merge URL"
  # Captured output is not a tty, so color must have degraded to plain text.
  case "$human" in
    *$'\033'*) fail "human output must be plain text when piped (no ANSI escapes)" ;;
  esac
  pass "sections bucket by attention owner and keep phase/owner/health separate"
}

test_reconcile_over_stale_status_log() {
  local home fakebin out
  home=$(make_home reconcile)
  mkdir -p "$home/projects/pending" "$home/projects/resumed-busy"
  # Idle pane: the needs-decision log line IS the current state -> NEEDS YOU.
  fm_write_meta "$home/state/pending-task.meta" \
    "window=firstmate:fm-pending-task" "worktree=$home/projects/pending" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'needs-decision: still open\n' > "$home/state/pending-task.status"
  # Busy pane: the same needs-decision log line is STALE; the gate resolved and
  # the crew resumed. Current state is working, so it must NOT land in NEEDS YOU.
  fm_write_meta "$home/state/resumed-task.meta" \
    "window=firstmate:fm-resumed-busy" "worktree=$home/projects/resumed-busy" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'needs-decision: already answered and resumed\n' > "$home/state/resumed-task.status"

  fakebin=$(make_fakebin "$home")
  out=$(run_json "$home" "$fakebin") || fail "reconcile --json must exit 0"
  printf '%s' "$out" | jq -e '
    ([.sections.needs_you[].id] == ["pending-task"])
      and ([.sections.running[].id] == ["resumed-task"])
      and ((.sections.running[] | select(.id == "resumed-task") | .phase) == "working")
  ' >/dev/null || fail "reconcile must follow current state, not the stale log verb: $out"

  # Determinism: same inputs twice, identical output.
  local a b
  a=$(run_json "$home" "$fakebin")
  b=$(run_json "$home" "$fakebin")
  [ "$a" = "$b" ] || fail "reduction must be deterministic for identical inputs"
  pass "reconciles over a stale status-log line and is deterministic"
}

test_graceful_unresolvable_task() {
  local home fakebin out human
  home=$(make_home unresolvable)
  # Worktree recorded but gone (torn down): fm-crew-state cannot resolve a
  # current state, so it reports unknown. The reducer must surface unknown and
  # never guess, and must still exit 0.
  fm_write_meta "$home/state/ghost-task.meta" \
    "window=firstmate:fm-ghost-task" "worktree=$home/projects/gone" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: was mid task before the worktree vanished\n' > "$home/state/ghost-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(run_json "$home" "$fakebin") || fail "unresolvable --json must exit 0"
  printf '%s' "$out" | jq -e '
    def row($id): (.sections.needs_you + .sections.at_risk + .sections.running)[] | select(.id == $id);
    (row("ghost-task") | .phase == "unknown")
  ' >/dev/null || fail "an unresolvable task must be classified unknown, not guessed: $out"
  human=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FLEET_STATUS_NOW="$NOW" "$STATUS") \
    || fail "unresolvable human must exit 0"
  assert_contains "$human" "unknown" "unresolvable task should render as unknown"
  pass "unresolvable task is surfaced as unknown and never crashes"
}

test_section_filter() {
  local home fakebin out
  home=$(make_home filter)
  mkdir -p "$home/projects/dec"
  fm_write_meta "$home/state/dec-task.meta" \
    "window=firstmate:fm-dec-task" "worktree=$home/projects/dec" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'needs-decision: pick one\n' > "$home/state/dec-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FLEET_STATUS_NOW="$NOW" "$STATUS" --json --section needs-you) \
    || fail "--section needs-you --json must exit 0"
  printf '%s' "$out" | jq -e '(. | type) == "array" and .[0].id == "dec-task"' >/dev/null \
    || fail "--json --section should print just that section array: $out"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$STATUS" --section bogus >/dev/null 2>&1 \
    && fail "an invalid --section must exit non-zero"
  pass "--section filters the projection and rejects unknown names"
}

test_repo_normalizes_project_path() {
  local home fakebin out
  home=$(make_home reponorm)
  mkdir -p "$home/projects/myrepo"
  # No backlog record, so repo_of falls back to the meta project value, which
  # fm-spawn records as an ABSOLUTE path. The JSON repo field must be the short
  # basename, consistent with done_records' short repo names, not a full path.
  fm_write_meta "$home/state/norepo-task.meta" \
    "window=firstmate:fm-norepo-task" "worktree=$home/projects/myrepo" \
    "project=$home/projects/myrepo" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: implementing\n' > "$home/state/norepo-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(run_json "$home" "$fakebin") || fail "repo-normalize --json must exit 0"
  printf '%s' "$out" | jq -e '
    def row($id): (.sections.needs_you + .sections.at_risk + .sections.running)[] | select(.id == $id);
    (row("norepo-task") | .repo == "myrepo")
  ' >/dev/null || fail "repo must normalize an absolute project path to its basename: $out"
  pass "repo normalizes an absolute project path to its short basename"
}

test_empty_fleet
test_section_bucketing_by_owner
test_reconcile_over_stale_status_log
test_graceful_unresolvable_task
test_section_filter
test_repo_normalizes_project_path
