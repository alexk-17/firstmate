#!/usr/bin/env bash
# tests/fm-dock-tui-pty.test.sh - pseudo-terminal integration tests for the Fleet
# Dock full-screen TUI's raw-mode input/refresh loop (bin/fm-dock.sh).
#
# The pure render/selection/dispatch core is covered by fm-dock-tui.test.sh; this
# file drives the ACTUAL loop through a real pty (via python3) to pin the three
# behaviors that a pure test cannot see and that a review caught escaping:
#
#   1. A payload prompt (answer/note) must queue ONLY the entered line - no
#      terminal-control bytes. The earlier bug ran the prompt in command
#      substitution, so cursor/erase escapes were captured into the intent.
#   2. Ctrl-D / terminal EOF must exit the TUI cleanly (the never-hang guarantee),
#      not be swallowed as a refresh timeout.
#   3. An empty-but-present NO_COLOR= on a real tty must fall back to the plain
#      picker, never the full-screen TUI (NO_COLOR presence, not value).
#
# It also confirms the alternate screen is entered and left (terminal never
# wedged) on a normal quit. python3 drives the pty; the suite skips without it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (pty driver unavailable)"; exit 0; }

# The whole scenario runs inside one python3 pty driver so a single interpreter
# owns the master fd, the child lifecycle, and hard per-run kill timeouts. It
# prints TAP-style "ok -"/"not ok -" lines and exits nonzero on the first
# failure. Every wait DRAINS the master fd so the child never blocks writing into
# a full pty buffer (a pty deadlock), and the child is force-killed on timeout so
# a hung run can never wedge CI.
DOCK="$ROOT/bin/fm-dock.sh" python3 -u - "$ROOT" <<'PY'
import os, pty, select, signal, time, glob, json, tempfile, shutil, sys

DOCK = os.environ["DOCK"]

def new_home():
    home = tempfile.mkdtemp(prefix="fm-dock-pty.")
    state = os.path.join(home, "state"); os.makedirs(state)
    with open(os.path.join(state, "task-a1.meta"), "w") as f:
        f.write("window=x:fm-task-a1\nkind=ship\nharness=claude\nmode=no-mistakes\nproject=alpha\n")
    with open(os.path.join(state, "task-a1.status"), "w") as f:
        f.write("working: implementing\n")
    return home, state

def spawn(args, home, state, extra_env=None):
    env = dict(os.environ)
    env.update(FM_HOME=home, FM_STATE_OVERRIDE=state, TERM="xterm-256color",
               FM_DOCK_REFRESH="1", COLUMNS="100", LINES="30")
    env.pop("NO_COLOR", None)
    if extra_env:
        env.update(extra_env)
    pid, fd = pty.fork()
    if pid == 0:
        os.execve("/bin/bash", ["bash", DOCK] + args, env)
        os._exit(127)
    return pid, fd

def pump(fd, seconds):
    """Read/return whatever the child emits over the next <seconds> (draining so
    the child never blocks on a full pty buffer)."""
    out = b""; end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                c = os.read(fd, 65536)
                if not c:
                    break
                out += c
            except OSError:
                break
    return out

def finish(pid, fd, grace=6.0):
    """Wait for the child to exit while draining the master. Returns
    (exit_code_or_None, still_alive_bool, drained_bytes). Force-kills on timeout."""
    out = b""; end = time.time() + grace
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                c = os.read(fd, 65536)
                if c:
                    out += c
            except OSError:
                pass
        w, st = os.waitpid(pid, os.WNOHANG)
        if w:
            code = os.waitstatus_to_exitcode(st) if hasattr(os, "waitstatus_to_exitcode") else st
            out += pump(fd, 0.2)
            return code, False, out
    try:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    except OSError:
        pass
    return None, True, out

def intents(state):
    out = []
    for p in glob.glob(os.path.join(state, "captain-inbox", "*.json")) + \
             glob.glob(os.path.join(state, "captain-inbox", "done", "*.json")):
        try:
            out.append(json.load(open(p)))
        except Exception:
            pass
    return out

failed = False
def ok(cond, desc):
    global failed
    print(("ok - " if cond else "not ok - ") + desc)
    if not cond:
        failed = True

SMCUP = [b"\x1b[?1049h", b"\x1b[?47h"]
RMCUP = [b"\x1b[?1049l", b"\x1b[?47l"]

# --- 1. payload bytes: a note payload must be exactly the typed line ----------
home, state = new_home()
pid, fd = spawn(["--tui"], home, state)
buf = pump(fd, 2.0)                    # first render(s)
os.write(fd, b"n"); buf += pump(fd, 0.8)   # note action -> prompt
os.write(fd, b"hello from tui\r"); buf += pump(fd, 0.8)   # type payload + Enter
os.write(fd, b"q")                     # quit
code, alive, tail = finish(pid, fd); buf += tail
notes = [i for i in intents(state) if i.get("action") == "note"]
ok(len(notes) == 1, "a note action queued exactly one intent")
payload = notes[0]["payload"] if notes else "<none>"
ok(payload == "hello from tui",
   "payload is the entered line only, no terminal-control bytes (got %r)" % payload)
ok(any(s in buf for s in SMCUP), "TUI entered the alternate screen")
ok(any(s in buf for s in RMCUP), "TUI left the alternate screen on quit (not wedged)")
ok(not alive and code == 0, "TUI exited 0 on a normal quit (got %r, alive=%s)" % (code, alive))
shutil.rmtree(home, ignore_errors=True)

# --- 2. Ctrl-D / EOF exits the TUI --------------------------------------------
home, state = new_home()
pid, fd = spawn(["--tui"], home, state)
buf = pump(fd, 2.0)
os.write(fd, b"\x04")                  # Ctrl-D
code, alive, tail = finish(pid, fd); buf += tail
ok(not alive, "Ctrl-D / EOF exits the TUI (does not hang refreshing)")
ok(any(s in buf for s in RMCUP), "TUI left the alternate screen on EOF (not wedged)")
shutil.rmtree(home, ignore_errors=True)

# --- 3. NO_COLOR= (present, empty) on a real tty falls back to the picker ------
home, state = new_home()
pid, fd = spawn([], home, state, extra_env={"NO_COLOR": ""})   # default surface
buf = pump(fd, 1.5)
os.write(fd, b"q\r")                   # 'q' quits the picker's line prompt
code, alive, tail = finish(pid, fd); buf += tail
ok(not any(s in buf for s in SMCUP),
   "NO_COLOR= present selects the plain picker, never the alt-screen TUI")
ok(not alive and code == 0, "the NO_COLOR= picker exits cleanly and never hangs (got %r)" % code)
shutil.rmtree(home, ignore_errors=True)

sys.exit(1 if failed else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || fail "pty integration checks failed (see the not-ok lines above)"
pass "pty integration: payload bytes clean, Ctrl-D/EOF exits, NO_COLOR= falls back to the picker"
