#!/usr/bin/env bash
# fm-fleet-status.sh - prioritized, glanceable fleet digest.
#
# One read-only screen that answers "what needs me, what is at risk, what is
# running, what just finished" - so fleet state stops living only in the
# scrolling chat. It is a pure REDUCER over bin/fm-fleet-snapshot.sh --json (the
# same stable contract bin/fm-fleet-view.sh renders): this command never parses
# state files itself, so it inherits the snapshot's read-only guarantee and its
# reconciled current-state reads (bin/fm-crew-state.sh, which treats the
# append-only state/<id>.status log as an EVENT history, never current truth).
# Same snapshot in -> same digest out; the only wall-clock input is freshness
# age, pinnable via FM_FLEET_STATUS_NOW for reproducible output.
#
# Each in-flight task is reduced along THREE independent dimensions, never
# conflated:
#   phase   working | validating | needs-decision | ready | blocked | paused |
#           done | failed | unknown   (from current_state + meta)
#   owner   who owns the next move: crew | firstmate | captain | ci | external |
#           unknown   (needs-decision/ready -> captain; validating -> ci;
#           working -> crew; blocked/failed -> firstmate; paused -> external)
#   health  active | idle | stale | dead | unknown   (cheap endpoint/pane
#           liveness as fm-crew-state already resolves it; a `working` state read
#           only from the status log - source=status-log, i.e. no live run and an
#           idle pane - is treated as `stale`, a stopped-mid-work suspect)
#
# Output is four sections, in fixed priority order:
#   1. NEEDS YOU     owner==captain (a decision, a PR to merge, a local branch to
#                    approve, findings to read); prints the exact chat reply.
#   2. AT RISK       failed, dead, stale, or genuinely blocked work.
#   3. RUNNING       everything else in flight (working/validating/paused/done-
#                    awaiting-teardown); collapsed to one line each.
#   4. RECENTLY DONE compact outcomes from data/backlog.md's Done section,
#                    newest first, bounded (FM_FLEET_STATUS_DONE_LIMIT, default 8).
#
# This IS the state projection only. There is no command inbox, captain-input
# path, or refresh loop here; --watch is intentionally out of scope.
#
# Flags:
#   -h, --help          show usage.
#   --json              print the fm-fleet-status.v1 projection instead of the
#                       human digest (a machine-readable surface a future UI can
#                       consume). Never colored.
#   --section <name>    limit to one section: needs-you | at-risk | running |
#                       recently-done.
#
# Env:
#   FM_FLEET_STATUS_NOW=<epoch>    pin "now" for freshness ages (tests/repro).
#   FM_FLEET_STATUS_DONE_LIMIT=<n> cap the RECENTLY DONE list (default 8).
#   NO_COLOR / non-tty stdout      disable ANSI color (auto-degrades to plain).
# FM_HOME and the FM_*_OVERRIDE knobs are honored by the snapshot subprocess.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-status.sh [--json] [--section <name>]

Print a prioritized, read-only fleet digest reduced from fm-fleet-snapshot.sh.
Sections, in priority order: NEEDS YOU, AT RISK, RUNNING, RECENTLY DONE.

  --json             print the fm-fleet-status.v1 JSON projection (uncolored).
  --section <name>   one of: needs-you, at-risk, running, recently-done.
  -h, --help         show this help.

A --watch refresh loop is intentionally out of scope; re-run the command.
EOF
}

EMIT=human
SECTION=all
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) EMIT=json ;;
    --section)
      shift
      case "${1:-}" in
        needs-you|at-risk|running|recently-done) SECTION=$1 ;;
        *) echo "fm-fleet-status: --section needs one of: needs-you, at-risk, running, recently-done" >&2; exit 2 ;;
      esac
      ;;
    --section=*) set -- --section "${1#--section=}" "${@:2}"; continue ;;
    --watch|--watch=*)
      echo "fm-fleet-status: --watch is out of scope; re-run the command instead" >&2
      exit 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-status: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c (matches
# fm-supervision-lib.sh - never the `stat -f || stat -c` fallback form, which
# writes a partial filesystem dump on Linux).
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

NOW=${FM_FLEET_STATUS_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
DONE_LIMIT=${FM_FLEET_STATUS_DONE_LIMIT:-8}
case "$DONE_LIMIT" in ''|*[!0-9]*) DONE_LIMIT=8 ;; esac

# Freshness anchor per task: mtime of the status log (its last meaningful
# transition), else the meta file. jq cannot stat, so build an {id: epoch|null}
# map here and hand it in.
FRESH=$(
  printf '%s' "$SNAPSHOT" \
    | jq -r '.tasks[]? | "\(.id)\t\(.paths.status_log.path // "")\t\(.paths.meta.path // "")"' \
    | while IFS=$'\t' read -r id slog mfile; do
        epoch=""
        [ -n "$slog" ] && [ -f "$slog" ] && epoch=$(stat_mtime "$slog")
        [ -z "$epoch" ] && [ -n "$mfile" ] && [ -f "$mfile" ] && epoch=$(stat_mtime "$mfile")
        [ -n "$epoch" ] || epoch=null
        printf '%s\t%s\n' "$id" "$epoch"
      done \
    | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | if . == "null" then null else tonumber end)}] | add // {}'
)

COLOR=false
if [ "$EMIT" = human ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] && [ -t 1 ]; then
  COLOR=true
fi

printf '%s' "$SNAPSHOT" | jq -r \
  --argjson now "$NOW" \
  --argjson fresh "$FRESH" \
  --argjson color "$COLOR" \
  --argjson done_limit "$DONE_LIMIT" \
  --arg emit "$EMIT" \
  --arg section "$SECTION" '
  . as $snapshot

  # --- freshness --------------------------------------------------------------
  | def fresh_epoch($id): ($fresh[$id] // null);
    def age_text($id):
      fresh_epoch($id) as $e
      | if $e == null then "-"
        else (($now - $e) | if . < 0 then 0 else . end) as $s
          | if $s < 60 then "\($s)s"
            elif $s < 3600 then "\(($s/60)|floor)m"
            elif $s < 86400 then "\(($s/3600)|floor)h"
            else "\(($s/86400)|floor)d" end
        end;

  # --- per-task reduction -----------------------------------------------------
    def detail_of($t): ($t.current_state.detail // "");
    def is_ask_user($t): detail_of($t) | test("ask-user");
    def is_merged($t): detail_of($t) | test("merged|PR merged/closed");
    def repo_of($t):
      ($t.backlog.repo
       // ($t.project | if . == null or . == "" then null else (split("/") | last) end))
      | if . == null or . == "" then "-" else . end;
    def headline($t):
      detail_of($t) as $d
      | if $d != "" then $d
        elif ($t.hints.last_event_text // "") != "" then $t.hints.last_event_text
        else ($t.backlog.title // "-") end;

    def phase_of($t):
      $t.current_state.state as $s | $t.current_state.source as $src
      | if $t.kind == "secondmate" then
          (if $t.endpoint.exists == false or $t.endpoint.agent_alive == "dead" then "unknown"
           else "supervising" end)
        elif $s == "unknown" then "unknown"
        elif $s == "failed" then "failed"
        elif $s == "blocked" then "blocked"
        elif $s == "paused" then "paused"
        elif $s == "parked" then "needs-decision"
        elif $s == "done" then
          (if is_merged($t) then "done"
           elif $t.kind == "scout" then "done"
           elif ($t.pr.url != null) then "ready"
           elif ($t.mode == "local-only") then "ready"
           else "done" end)
        elif $s == "working" then
          (if $src == "run-step" then "validating" else "working" end)
        else "unknown" end;

    def health_of($t):
      $t.current_state.state as $s | $t.current_state.source as $src
      | if $t.kind == "secondmate" then
          (if $t.endpoint.exists == false or $t.endpoint.agent_alive == "dead" then "dead"
           elif $t.endpoint.agent_alive == "alive" then "active"
           else "idle" end)
        elif $t.endpoint.exists == false then "dead"
        elif $t.endpoint.exists == null then "unknown"
        elif $s == "working" then (if $src == "status-log" then "stale" else "active" end)
        elif $s == "unknown" then "stale"
        else "idle" end;

    def owner_of($t; $phase):
      if $phase == "unknown" then "unknown"
      elif $phase == "supervising" then "firstmate"
      elif $phase == "failed" then "firstmate"
      elif $phase == "needs-decision" then
        (if (is_ask_user($t) or $t.hints.pending_decision == true) then "captain" else "crew" end)
      elif $phase == "ready" then "captain"
      elif $phase == "blocked" then "firstmate"
      elif $phase == "paused" then "external"
      elif $phase == "validating" then "ci"
      elif $phase == "working" then "crew"
      elif $phase == "done" then (if $t.kind == "scout" then "captain" else "firstmate" end)
      else "unknown" end;

    # Section precedence: a captain-owned move is top priority even when the
    # crew endpoint is legitimately gone (a finished crew). A merged/relay `done`
    # awaiting firstmate is not "at risk", so it stays in RUNNING before the
    # dead/stale check can grab it.
    def section_of($phase; $owner; $health):
      if $owner == "captain" then "needs_you"
      elif $phase == "done" then "running"
      elif $phase == "failed" then "at_risk"
      elif $phase == "blocked" then "at_risk"
      elif $health == "dead" or $health == "stale" then "at_risk"
      else "running" end;

    def next_action($t; $phase; $owner):
      if $phase == "needs-decision" and $owner == "captain" then "your decision"
      elif $phase == "needs-decision" then "crew answering its own gate"
      elif $phase == "ready" and ($t.pr.url != null) then "merge when ready"
      elif $phase == "ready" then "review diff, then approve"
      elif $phase == "validating" then "checks / CI"
      elif $phase == "supervising" then "supervising its domain"
      elif $phase == "working" then "implementation in progress"
      elif $phase == "paused" then "waiting on external event"
      elif $phase == "blocked" then "firstmate to unblock"
      elif $phase == "failed" then "firstmate to recover"
      elif $phase == "done" and $t.kind == "scout" then "findings ready - read report"
      elif $phase == "done" then "ready to tear down"
      else "review" end;

    # The exact chat reply the captain can type. Only captain-owned rows carry one.
    def reply_syntax($t; $phase; $owner):
      if $owner != "captain" then null
      elif $phase == "needs-decision" then "\($t.id): <your decision>"
      elif $phase == "ready" and ($t.pr.url != null) then $t.pr.url
      elif $phase == "ready" then "\($t.id): approve"
      elif $phase == "done" and $t.kind == "scout" then ($t.paths.report.path // "\($t.id): read report")
      else null end;

    def task_row($t):
      phase_of($t) as $phase
      | health_of($t) as $health
      | owner_of($t; $phase) as $owner
      | {
          id: $t.id, kind: $t.kind, repo: repo_of($t),
          phase: $phase, owner: $owner, health: $health,
          section: section_of($phase; $owner; $health),
          headline: headline($t),
          next_action: next_action($t; $phase; $owner),
          reply_syntax: reply_syntax($t; $phase; $owner),
          pr_url: $t.pr.url,
          freshness: {epoch: fresh_epoch($t.id), age: age_text($t.id)},
          # Strip the volatile wall-clock observed_at from the snapshot: this is a
          # pure reduction of fleet state, so identical inputs must reduce
          # identically regardless of the second the snapshot was taken (freshness carries age).
          current_state: ($t.current_state | del(.observed_at))
        };

    def done_records:
      [$snapshot.backlog.records[]? | select(.state == "done")]
      | map({
          id: (.id // "-"), title: (.title // .raw // "-"),
          repo: (.repo // "-"), kind: (.kind // "-"),
          artifact: (.pr_url // .report_path // .local_note // "-"),
          date: (.completion.date // null)})
      | sort_by(.date // "") | reverse | .[0:$done_limit];

  # --- section assembly -------------------------------------------------------
  ([($snapshot.tasks // [])[] | task_row(.)]) as $rows
  | ([$rows[] | select(.section == "needs_you")]
      | sort_by([(if .phase == "needs-decision" then 0
                  elif .phase == "ready" and .pr_url != null then 1
                  elif .phase == "ready" then 2 else 3 end),
                 (.freshness.epoch // $now)])) as $needs_you
  | ([$rows[] | select(.section == "at_risk")]
      | sort_by([(if .phase == "failed" then 0
                  elif .health == "dead" then 1
                  elif .health == "stale" then 2
                  elif .phase == "blocked" then 3 else 4 end),
                 (.freshness.epoch // $now)])) as $at_risk
  | ([$rows[] | select(.section == "running")]
      | sort_by([(if .phase == "working" then 0
                  elif .phase == "validating" then 1
                  elif .phase == "needs-decision" then 2
                  elif .phase == "paused" then 3
                  elif .phase == "done" then 4 else 5 end),
                 .id])) as $running
  | done_records as $recently_done

  | {schema: "fm-fleet-status.v1", fm_home: $snapshot.fm_home,
     generated_epoch: $now,
     sections: {needs_you: $needs_you, at_risk: $at_risk,
                running: $running, recently_done: $recently_done}} as $proj

  # --- emit -------------------------------------------------------------------
  | def esc($code): if $color then "\u001b[\($code)m" else "" end;
    def reset: esc("0");
    def paint($code; $s): esc($code) + $s + reset;
    def phase_color($p):
      if $p == "failed" then "31"
      elif $p == "blocked" then "31"
      elif $p == "needs-decision" then "33"
      elif $p == "paused" then "35"
      elif $p == "ready" then "32"
      elif $p == "done" then "32"
      elif $p == "validating" then "36"
      elif $p == "working" then "34"
      else "2" end;
    def health_color($h):
      if $h == "dead" then "31"
      elif $h == "stale" then "33"
      elif $h == "active" then "32"
      else "2" end;

    def render_inflight($r):
      ("  " + paint("1"; $r.id)
        + "  " + paint(phase_color($r.phase); $r.phase)
        + " " + esc("2") + "·" + reset + " " + $r.owner
        + " " + esc("2") + "·" + reset + " " + paint(health_color($r.health); $r.health)
        + " " + esc("2") + "· " + $r.freshness.age + reset),
      ("      " + esc("2") + ($r.headline // "-") + reset),
      ("      " + esc("2") + "->" + reset + " " + $r.next_action),
      (if $r.reply_syntax != null then "      " + paint("36;1"; "reply: " + $r.reply_syntax) else empty end);

    def render_done($r):
      "  " + paint("1"; $r.id) + "  " + esc("2") + ($r.title // "-") + reset
        + "  " + esc("2") + "[" + $r.repo + "] " + $r.artifact + reset;

    def block_header($title; $code; $rows):
      paint($code + ";1"; $title) + paint("2"; "  (\($rows | length))");
    def inflight_block($title; $code; $rows; $empty_note):
      [ block_header($title; $code; $rows),
        (if ($rows | length) == 0 then ("  " + esc("2") + $empty_note + reset)
         else ($rows[] | render_inflight(.)) end),
        "" ];
    def done_block($title; $code; $rows; $empty_note):
      [ block_header($title; $code; $rows),
        (if ($rows | length) == 0 then ("  " + esc("2") + $empty_note + reset)
         else ($rows[] | render_done(.)) end),
        "" ];
    def want($name): $section == "all" or $section == $name;

    if $emit == "json" then
      if $section == "all" then $proj
      elif $section == "needs-you" then $proj.sections.needs_you
      elif $section == "at-risk" then $proj.sections.at_risk
      elif $section == "running" then $proj.sections.running
      else $proj.sections.recently_done end
    else
      [ (if $section == "all" then
           [ (paint("1;36"; "Fleet status") + paint("2"; "  " + $snapshot.fm_home)), "" ]
         else empty end),
        (if want("needs-you") then
           inflight_block("NEEDS YOU"; "33"; $needs_you; "Nothing needs you right now.")
         else empty end),
        (if want("at-risk") then
           inflight_block("AT RISK"; "31"; $at_risk; "Nothing at risk.")
         else empty end),
        (if want("running") then
           inflight_block("RUNNING"; "36"; $running; "No tasks in flight.")
         else empty end),
        (if want("recently-done") then
           done_block("RECENTLY DONE"; "32"; $recently_done; "No recently completed work.")
         else empty end)
      ] | flatten | .[]
    end
  '
