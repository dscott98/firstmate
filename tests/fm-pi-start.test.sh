#!/usr/bin/env bash
# Portable Pi startup gate regression: real terminal processes, no Pi install.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-start-lib.sh"
command -v tmux >/dev/null || { echo 'skip: tmux required'; exit 0; }
LAB=$(fm_test_tmproot fm-pi-start)
REAL_TMUX=$(command -v tmux)
SOCKET="$LAB/socket"
mkdir -p "$LAB/bin"
cat > "$LAB/bin/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -S '$SOCKET' "\$@"
EOF
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
"$REAL_TMUX" -S "$SOCKET" -f /dev/null new-session -d -s test -x 120 -y 30
export FM_PI_READY_POLLS=20 FM_PI_POLL_INTERVAL=0.1

run_case() {
  local name=$1 selected=$2 action=$3 expected=$4 rc=0
  local dir="$LAB/$name"
  mkdir -p "$dir"
  cat > "$dir/terminal.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
cd "$1"
stty -echo
printf '\033[2J\033[HTrust project folder?\n%s\n\n%s\n  Do not trust\n↑↓ navigate  enter select  escape cancel\n' "$PWD" "$2"
if [ "$3" = history ]; then
  for _ in $(seq 1 45); do printf 'history spacer\n'; done
fi
printf painted > painted
if [ "$3" = remembered ]; then
  printf '\033[2J\033[H'
  printf 'agent-start\n' > receipt
fi
while IFS= read -r answer; do
  printf 'enter\n' >> keys
  case "$3" in
    start) printf '\033[2J\033[H'; printf 'agent-start\n' > receipt ;;
    clear) printf '\033[2J\033[Hpi ready\n' ;;
  esac
done
EOF
  tmux new-window -d -t test -n "$name" "bash '$dir/terminal.sh' '$dir' '$selected' '$action'"
  for _ in $(seq 1 100); do [ ! -f "$dir/painted" ] || break; sleep 0.1; done
  [ -f "$dir/painted" ] || fail 'terminal did not paint'
  if [ "$action" = history ]; then
    assert_contains "$(fm_backend_capture tmux "test:$name" 100 "$name")" 'Trust project folder?' 'history fixture lost its stale dialog'
    assert_not_contains "$(fm_backend_visible_capture tmux "test:$name" "$name")" 'Trust project folder?' 'history fixture did not blind the viewport'
  fi
  fm_pi_wait_for_start tmux "test:$name" "$name" "$dir/receipt" 'pi-test 0.0' >"$dir/out" 2>&1 || rc=$?
  expect_code "$expected" "$rc" "$name gate verdict"
  case "$action" in
    start|clear|stall) [ "$(wc -l < "$dir/keys" | tr -d ' ')" = 1 ] || fail "$name repeated Enter" ;;
    *) [ ! -f "$dir/keys" ] || fail "$name selected an unsafe item" ;;
  esac
  if [ "$expected" = 0 ]; then
    # Split structural progress from UI appearance deliberately: a blank screen
    # succeeds solely on the durable event, without a banner/brief echo/spinner.
    pane=$(fm_backend_visible_capture tmux "test:$name" "$name")
    assert_not_contains "$pane" 'Trust project folder?' 'dialog did not leave viewport'
  else
    assert_contains "$(cat "$dir/out")" 'pi-test 0.0 did not confirm agent_start' 'failure lacks harness/version'
  fi
  tmux kill-window -t "test:$name"
  pass "$name"
}
run_case fresh '→ Trust' start 0
run_case remembered '→ Trust parent folder (/parent)' remembered 0
run_case stalled '→ Trust' stall 1
run_case cleared-without-processing '→ Trust' clear 1
run_case parent-selected '→ Trust parent folder (/parent)' never 1
run_case session-selected '→ Trust (this session only)' never 1
run_case partial 'Trust' never 1
run_case history-only '→ Trust' history 1

for backend in orca cmux; do
  rc=0
  fm_pi_wait_for_start "$backend" absent absent "$LAB/absent" 'pi-signed 0.0' >"$LAB/out" 2>&1 || rc=$?
  expect_code 1 "$rc" "$backend must refuse unverified capture"
  assert_contains "$(cat "$LAB/out")" "pi-signed 0.0 startup needs a verified viewport capture" 'capability diagnostic'
done
pass 'unsupported viewport providers refuse'

# Execute the actual generated extension interface, with a synthetic event
# emitter. A relaunch's unique path cannot be satisfied by the previous receipt.
printf 'supplied brief\n' > "$LAB/prompt"
fm_pi_start_extension "$LAB/event-ready" "$LAB/prompt" > "$LAB/extension.mjs"
node --input-type=module - "$LAB/extension.mjs" "$LAB/event-ready" <<'JS'
import {pathToFileURL} from 'node:url';
import {existsSync,readFileSync} from 'node:fs';
const [file, receipt] = process.argv.slice(2);
const events = new Map();
(await import(pathToFileURL(file))).default({on: (name, fn) => events.set(name, fn)});
if (existsSync(receipt)) throw Error('extension load claimed processing');
await events.get('session_start')?.();
if (existsSync(receipt)) throw Error('session_start claimed processing');
await events.get('before_agent_start')({prompt: 'unrelated startup message'});
await events.get('agent_start')();
if (existsSync(receipt)) throw Error('unrelated turn claimed brief processing');
await events.get('before_agent_start')({prompt: 'supplied brief'});
await events.get('agent_start')();
await events.get('agent_start')();
if (readFileSync(receipt, 'utf8') !== 'agent-start\n') throw Error('missing durable start');
JS
rc=0
FM_PI_READY_POLLS=1 fm_pi_wait_for_start tmux test test "$LAB/relaunch-ready" 'pi 0.0' >"$LAB/out" 2>&1 || rc=$?
expect_code 1 "$rc" 'old incarnation must not satisfy relaunch'
pass 'agent_start receipt is durable, idempotent and incarnation bound'
