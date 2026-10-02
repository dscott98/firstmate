#!/usr/bin/env bash
# tests/fm-remote-task-lifecycle-e2e.test.sh - a sandbox task supervised from
# its primary home, from spawn through its worker's own status lines: the
# status mirror armed at publish, a mirrored decision, a steer that answers it
# with --resolve-key, peek, the composed current state, and a scout's report
# landing before the terminal line that announces it.
#
# The harness is the placement suite's (tests/fm-remote-task-spawn.test.sh): a
# real supervising home with a markdown backlog, a registered project with a
# file:// origin, a brief rendered by the real fm-brief.sh for the sandbox
# home, a configured fake provider, and spawn run from a committed copy of this
# checkout. The fake ssh is bin/fm-on.sh's FM_SSH_BIN seam: it decodes the
# fixed entrypoint's arguments and runs the named command from that code root
# against the sandbox home under an empty environment, with the sandbox
# account's HOME and a fake tmux, treehouse, Pi, and no-mistakes first on
# PATH. Provisioning, launch, the delta reader, the confined file reader, and
# every control verb are therefore the real host-side scripts. The test plays
# the worker: it appends to the sandbox home's status file, writes the scout's
# report, and posts Pi busy events. The process-event runner is started the
# way the watcher's reconcile starts it, and a tripwire tmux on the supervising
# side records any local call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
unset TASKS_AXI_BACKEND || :

TMP_ROOT=$(fm_test_tmproot fm-remote-task-lifecycle)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$
PI_SECRET="sk-LIFECYCLEPISECRET${RUN_ID}x"

# Host-side spawns stage per-task temp roots at /tmp/fm-<id>, outside every
# fixture, so task ids carry this run's id and the roots are removed here.
cleanup() {
  rm -rf /tmp/fm-rtl-*-"$RUN_ID" /tmp/fm-rtl-*-"$RUN_ID"+* 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- shared fixtures -----------------------------------------------------------

CODE_ROOT="$TMP_ROOT/code-root"
mkdir -p "$CODE_ROOT"
(cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state \
  --exclude=config --exclude=projects -cf - .) | (cd "$CODE_ROOT" && tar -xf -)
git -C "$CODE_ROOT" init -q -b main
git -C "$CODE_ROOT" add -A
git -C "$CODE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'code root fixture'
SPAWN="$CODE_ROOT/bin/fm-spawn.sh"
BRIEF="$CODE_ROOT/bin/fm-brief.sh"

ORIGIN="$TMP_ROOT/alpha.git"
fm_git_init_commit "$TMP_ROOT/alpha-seed"
git init -q --bare "$ORIGIN"
git -C "$TMP_ROOT/alpha-seed" push -q "$ORIGIN" HEAD:refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

CREDS="$TMP_ROOT/creds"
mkdir -p "$CREDS"
(umask 077; printf '%s' "$PI_SECRET" > "$CREDS/minimax.key")

LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$LOCAL_BIN"
cat > "$LOCAL_BIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LOCAL_TMUX_LOG:?}"
exit 1
SH
chmod +x "$LOCAL_BIN/tmux"

PROVIDER_DIR="$TMP_ROOT/provider"
mkdir -p "$PROVIDER_DIR"
PROVIDER="$PROVIDER_DIR/pve-sandbox"
cat > "$PROVIDER" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_PROVIDER_STATE:?}
printf '%s\n' "$*" >> "$d/argv.log"
case "${1:-}" in
  create)
    id=$2
    shift 2
    home= profile=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home) home=$2; shift 2 ;;
        --profile) profile=$2; shift 2 ;;
        --ttl) shift 2 ;;
        *) exit 64 ;;
      esac
    done
    printf '%s %s\n' "$id" "$home" > "$d/vm.sbx-$id"
    printf 'name=sbx-%s vmid=101 node=pve1 ssh_alias=alias-%s user=agent profile=%s ttl_expires=2026-10-05T12:00:00Z hostkey=pinned\n' \
      "$id" "$id" "$profile"
    ;;
  status)
    if [ -f "$d/vm.$2" ]; then
      read -r id home < "$d/vm.$2"
      printf 'name=%s state=running fm_task=%s fm_home=%s hold=yes\n' "$2" "$id" "$home"
    else
      printf 'name=%s state=absent\n' "$2"
    fi
    ;;
  exec)
    shift 3
    case "$*" in *' pull '*) exit 0 ;; esac
    exec "$@"
    ;;
  destroy)
    printf '%s\n' "$2" >> "$d/destroyed.log"
    rm -f "$d/vm.$2"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$PROVIDER"

HOST_BIN="$TMP_ROOT/host-bin"
mkdir -p "$HOST_BIN"
fm_fake_exit0 "$HOST_BIN" treehouse
cat > "$HOST_BIN/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' '--approve' ;;
  --version) printf 'fake-pi\n' ;;
esac
SH
cat > "$HOST_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$HOST_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_TMUX_DIR:?}
printf '%s\n' "$*" >> "$d/log"
case "$*" in
  *"#{pane_current_path}"*) cat "$d/pane-path" 2>/dev/null; exit 0 ;;
  *"#{pane_tty}"*) printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*) cat "$d/pane-command" 2>/dev/null || printf 'claude\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
esac
case "${1:-}" in
  list-sessions)
    [ -f "$d/server" ] || { echo "no server running on $d/socket" >&2; exit 1; }
    printf 'firstmate: 1 windows\n'
    ;;
  has-session) [ -f "$d/server" ] ;;
  new-session) : > "$d/server" ;;
  show-environment)
    [ -f "$d/env.${3:-}" ] || { echo "unknown variable: ${3:-}" >&2; exit 1; }
    printf '%s=%s\n' "$3" "$(cat "$d/env.$3")"
    ;;
  list-windows)
    [ -f "$d/server" ] || { echo "no server running on $d/socket" >&2; exit 1; }
    [ -f "$d/window" ] || exit 0
    case "$*" in
      *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "$(cat "$d/window")" ;;
      *) cat "$d/window" ;;
    esac
    ;;
  new-window)
    : > "$d/server"
    while [ "$#" -gt 0 ]; do
      case "$1" in -n) shift; printf '%s\n' "$1" > "$d/window" ;; esac
      shift
    done
    printf '@1\n'
    ;;
  kill-window) rm -f "$d/window" ;;
  capture-pane) cat "$d/pane" 2>/dev/null || printf 'fake pane line\n' ;;
  display-message) printf 'firstmate\n' ;;
  send-keys)
    case "$*" in
      *"/launch."*)
        printf 'pi\n' > "$d/pane-command"
        if [[ "$*" =~ (/tmp/fm-[^\'[:space:]]+)/launch\.([^\'[:space:]]+)\.sh ]]; then
          printf 'agent-start\n' > "${BASH_REMATCH[1]}/pi-start.${BASH_REMATCH[2]}.ready"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$HOST_BIN/pi" "$HOST_BIN/no-mistakes" "$HOST_BIN/tmux"

# The transport: every command runs from the code root against the sandbox
# home under an empty environment, as the remote job worker runs it. A
# FM_FAKE_SLOW_FETCH delay before the confined file reader widens the window
# in which a report fetch is still in flight.
cat > "$LOCAL_BIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1 entry=$2
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$4" | base64 --decode)
home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
cmd=${args[0]}
verb=${args[1]:-}
printf '%s %s %s\n' "$host" "$cmd" "$verb" >> "$FM_FAKE_SSH_LOG"
[ "$host" = "$FM_FAKE_SSH_HOST" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
if [ "$cmd" = fm-remote-doctor.sh ]; then
  printf 'check harness=ok: pi\nok: task readiness confirmed on this host\n'
  exit 0
fi
if [ "$cmd" = fm-remote-file.sh ] && [ -n "${FM_FAKE_SLOW_FETCH:-}" ]; then
  sleep "$FM_FAKE_SLOW_FETCH"
fi
if [ "$cmd" = fm-remote-task-control.sh ] && [ "$verb" = launch ] && [ ! -d "$FM_FAKE_HOST_DIR/wt" ]; then
  # Stand in for treehouse: the slot the host's spawn adopts from the pane.
  git -C "$home/projects/alpha" worktree add -q --detach "$FM_FAKE_HOST_DIR/wt" >/dev/null 2>&1 || exit 93
  printf '%s\n' "$FM_FAKE_HOST_DIR/wt" > "$FM_FAKE_HOST_DIR/tmux/pane-path"
fi
exec env -i PATH="$FM_FAKE_HOST_BIN:$PATH" HOME="$FM_FAKE_HOST_DIR/account" \
  TMPDIR="$FM_FAKE_HOST_DIR/tmp" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR= \
  FM_FAKE_TMUX_DIR="$FM_FAKE_HOST_DIR/tmux" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
  "$root/bin/$cmd" "${args[@]:1}"
SH
chmod +x "$LOCAL_BIN/fake-ssh"

# --- per-case homes --------------------------------------------------------------

# new_case <name> [kind]: a supervising home with one registered project, a
# configured provider whose sandbox home is this case's, a markdown backlog
# holding the task, and a fresh sandbox host. Sets CASE, ID, PRIMARY, HOST_DIR,
# HOST_HOME, CLAIMS, and SID.
new_case() {
  local name=$1 kind=${2:-ship}
  CASE="$TMP_ROOT/$name"
  ID="rtl-$name-$RUN_ID"
  PRIMARY="$CASE/primary"
  HOST_DIR="$CASE/host"
  HOST_HOME="$HOST_DIR/fm-home"
  CLAIMS="$CASE/claims"
  SID="remote-reply-$ID"
  mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects" \
    "$HOST_DIR/tmp" "$HOST_DIR/tmux" "$HOST_DIR/account" "$CASE/provider" "$CLAIMS"
  git clone -q "file://$ORIGIN" "$PRIMARY/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha fixture (added 2026-10-01)' > "$PRIMARY/data/projects.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PRIMARY/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$PRIMARY/.tasks.toml"
  tasks-axi add "$ID" "sandbox lifecycle fixture $name" --kind "$kind" --file "$PRIMARY/data/backlog.md" >/dev/null \
    || fail "could not file the backlog item for $ID"
  printf '%s\n' "$PROVIDER" default_profile=default ttl=4h "ssh_include=$TMP_ROOT/ssh-include" \
    > "$PRIMARY/config/sandbox-provider"
  printf 'minimax  pi:minimax  %s\n' "$CREDS/minimax.key" > "$PRIMARY/config/sandbox-credentials"
  fm_test_track_procevent_home "$PRIMARY" "$CLAIMS"
}

# sandbox_brief [fm-brief args...]: the real scaffold for this case's sandbox
# home, filled.
sandbox_brief() {
  local file content
  FM_HOME="$PRIMARY" "$BRIEF" "$ID" alpha "$@" --for-home "$HOST_HOME" --for-root "$CODE_ROOT" >/dev/null \
    || fail "fm-brief.sh could not render the brief for $ID"
  file="$PRIMARY/data/$ID/brief.md"
  content=$(cat "$file")
  content=${content//'{TASK}'/Make the sandbox change.}
  content=${content//'{FIRSTMATE_SPEC}'/Build only what the intent asks.}
  printf '%s\n' "$content" > "$file"
}

# primary_env <command...>: run one supervising-home command with this case's
# transport and process-event claim root.
primary_env() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u FM_ROOT_OVERRIDE -u TRACEPARENT -u TMUX -u TMUX_PANE \
    FM_HOME="$PRIMARY" FM_SPAWN_NO_GUARD=1 FM_TEST_SEAM=1 FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    FM_TEST_SANDBOX_ROOT="$CODE_ROOT" FM_TEST_SANDBOX_HOME="$HOST_HOME" PATH="$LOCAL_BIN:$PATH" \
    FM_SSH_BIN="$LOCAL_BIN/fake-ssh" FM_FAKE_SSH_HOST="alias-$ID" FM_FAKE_SSH_LOG="$CASE/ssh.log" \
    FM_FAKE_HOST_DIR="$HOST_DIR" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_PROVIDER_STATE="$CASE/provider" FM_FAKE_LOCAL_TMUX_LOG="$CASE/local-tmux.log" \
    FM_REMOTE_REPLY_WAIT_SECONDS=5 FM_CREW_STATE_NO_FORGE=1 FM_FAKE_SLOW_FETCH="${FM_FAKE_SLOW_FETCH:-}" \
    "$@"
}

run_spawn() { # <spawn args...>; sets OUT and RC, with stderr in OUT
  OUT=$(primary_env "$SPAWN" "$@" 2>&1)
  RC=$?
}

# start_mirror: run the armed source's listener exactly as the watcher's
# reconcile launches it, then wait for its claim.
start_mirror() {
  primary_env "$CODE_ROOT/bin/fm-procevent.sh" start "$SID" > "$CASE/runner.out" 2>&1 &
  for _ in $(seq 1 200); do
    [ -f "$CLAIMS/$SID.claim" ] && return 0
    sleep 0.05
  done
  fail "the status mirror's listener never claimed $SID: $(cat "$CASE/runner.out")"
}

worker_appends() { # <line>...: the sandboxed worker appends to its own status file
  printf '%s\n' "$@" >> "$HOST_HOME/state/$ID.status"
}

wait_for_mirrored() { # <fixed-string> <label>
  for _ in $(seq 1 400); do
    grep -qF -- "$1" "$PRIMARY/state/$ID.status" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "$2: never mirrored into the primary status log: $(cat "$CASE/runner.out")"
}

pi_busy_event() { # <busy|idle> <event>: the worker's Pi extension posts its turn state
  local gen
  gen=$(sed -n 's/^busy_gen=//p' "$HOST_HOME/state/$ID.meta" | head -n 1)
  [ -n "$gen" ] || fail "the sandbox worker's record carries no busy generation"
  env -i PATH="$PATH" "$CODE_ROOT/bin/fm-busy-event.sh" apply "$HOST_HOME/state" "$ID" "$1" \
    --gen "$gen" --source pi-ext --event "$2" >/dev/null || fail "the fake Pi extension could not post $1"
}

crew_state() {
  local line
  line=$(primary_env "$CODE_ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  [ "${FM_TEST_EVIDENCE:-0}" != 1 ] || printf 'crew-state: %s\n' "$line" >&2
  printf '%s\n' "$line"
}

signal_pending() { # 0 while the primary status log holds bytes no wake has reported
  ! FM_STATE_OVERRIDE="$PRIMARY/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_signal_seen_current "$2/state" "$2/state/$3.status"
  ' _ "$CODE_ROOT" "$PRIMARY" "$ID"
}

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

# --- a ship: decision, steer, peek, and composed state ---------------------------

test_ship_decision_steer_peek_and_state() {
  local open out rc inbox body seq
  new_case ship
  sandbox_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox ship should launch"$'\n'"$OUT"
  assert_present "$PRIMARY/state/procevent/$SID.source" "spawn arms the status mirror at publish"
  start_mirror

  # The worker raises a decision on its host; the mirror lands it in this
  # home's status log, where the shared fold and the watcher's scan see it.
  worker_appends "working [at=1700000000]: rebasing the change" \
    "needs-decision [key=pick-base] [at=1700000100]: rebase onto main or onto release?"
  wait_for_mirrored "needs-decision [key=pick-base]" "the worker's decision"
  assert_grep "working [at=1700000000]: rebasing the change" "$PRIMARY/state/$ID.status" \
    "the worker's progress line is mirrored with its own time"
  open=$(status_open_decisions "$PRIMARY/state/$ID.status")
  printf '%s' "$open" | grep -q '^pick-base	needs-decision	' \
    || fail "the mirrored decision is not open in this home's fold: $open"
  signal_pending || fail "the mirrored decision is invisible to the watcher's signal scan"
  if [ -e "$PRIMARY/state/.wake-queue" ] && grep -q "procevent remote-reply $SID" "$PRIMARY/state/.wake-queue"; then
    fail "a fully applied mirror capture also published a check wake"
  fi

  # With the worker idle on its host, the current state comes from this
  # home's fold: parked on the decision.
  pi_busy_event idle agent_settled
  out=$(crew_state)
  assert_contains "$out" "state: parked · source: status-log · rebase onto main or onto release? · sandbox host alias-$ID" \
    "an idle worker with an open decision reads parked from the mirrored fold"

  # Peek reads the worker's pane on its host.
  printf 'pi> which base should I rebase onto?\n' > "$HOST_DIR/tmux/pane"
  out=$(primary_env "$CODE_ROOT/bin/fm-peek.sh" "$ID" 20 2>/dev/null); rc=$?
  expect_code 0 "$rc" "peek of the sandbox worker"
  assert_contains "$out" "which base should I rebase onto?" "peek prints the sandbox pane"
  grep -q "^alias-$ID fm-remote-task-control.sh capture$" "$CASE/ssh.log" || fail "peek did not reach the host's capture verb"

  # The answer crosses to the worker's inbox on its host; the decision closes
  # in this home's authoritative log at answer time.
  out=$(primary_env "$CODE_ROOT/bin/fm-send.sh" "$ID" --resolve-key pick-base 'rebase onto main' 2>&1); rc=$?
  expect_code 0 "$rc" "the steer that answers the decision"$'\n'"$out"
  inbox="$HOST_HOME/state/$ID.inbox"
  assert_present "$inbox/001.msg" "the steer is a durable record in the sandbox worker's inbox"
  body=$(sed -n '/^--$/,$p' "$inbox/001.msg" | sed '1d')
  assert_equals 'rebase onto main' "$body" "the inbox record carries exactly the answer"
  grep -Eq '^request=[a-f0-9]{16}$' "$inbox/001.msg" || fail "the sandbox steer carries no request id"
  assert_grep 'resolved [key=pick-base]' "$PRIMARY/state/$ID.status" "the answer closes the decision in this home"
  assert_not_contains "$(status_open_decisions "$PRIMARY/state/$ID.status")" $'pick-base\t' \
    "the answered decision is still open"
  assert_no_grep 'resolved' "$HOST_HOME/state/$ID.status" "the close stays in this home; only the answer crosses"
  assert_absent "$PRIMARY/state/$ID.inbox" "no local inbox is written for a sandbox task"
  grep -q 'Firstmate instruction waiting' "$HOST_DIR/tmux/log" || fail "the sandbox doorbell never rang"

  # The worker's own log still holds the decision open, but this home's fold
  # is authoritative: an idle worker no longer reads parked.
  out=$(crew_state)
  assert_not_contains "$out" "state: parked" "the host's stale decision overrode this home's close"
  assert_contains "$out" "sandbox host alias-$ID" "the composed state names its sandbox host"
  pi_busy_event busy agent_start
  out=$(crew_state)
  assert_contains "$out" "state: working · source: pane · harness busy (pi-ext) · sandbox host alias-$ID" \
    "a busy worker reads working from the host's busy component"

  # An identical later steer is a new instruction, never folded into the
  # acknowledged record.
  mv "$inbox/001.msg" "$inbox/handled/"
  primary_env "$CODE_ROOT/bin/fm-send.sh" "$ID" 'rebase onto main' >/dev/null 2>&1 \
    || fail "an identical later steer was not sent"
  assert_present "$inbox/002.msg" "an identical later steer lands as its own record"

  # Later worker lines keep flowing, each exactly once.
  worker_appends "working [at=1700000200]: rebased onto main, running the suite"
  wait_for_mirrored "rebased onto main, running the suite" "a later progress line"
  seq=$(grep -cF "needs-decision [key=pick-base]" "$PRIMARY/state/$ID.status")
  assert_equals 1 "$seq" "the decision line was mirrored more than once"
  assert_absent "$CASE/local-tmux.log" "a sandbox task never touches local tmux"
  pass "a sandbox ship's decision mirrors, its answer steers and closes it, and peek and crew-state read the host"
}

# --- a scout: its report is local before its terminal line ---------------------

test_scout_report_lands_before_its_terminal_line() {
  local report early
  new_case scout scout
  sandbox_brief --scout
  run_spawn "$ID" "$PRIMARY/projects/alpha" --scout --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox scout should launch"$'\n'"$OUT"
  FM_FAKE_SLOW_FETCH=1 start_mirror

  report="$HOST_HOME/data/$ID/report.md"
  printf '# Findings\n\nThe cache key omits the locale.\n' > "$report"
  # Watch this home's status log the way the watcher would, while the report
  # fetch is held open: the terminal line must never be visible before the
  # report it announces is local.
  early="$CASE/early-terminal-line"
  (
    for _ in $(seq 1 600); do
      if grep -qF 'done [at=1700000300]: report ready' "$PRIMARY/state/$ID.status" 2>/dev/null; then
        [ -f "$PRIMARY/data/$ID/report.md" ] || : > "$early"
        exit 0
      fi
      sleep 0.02
    done
  ) &
  local watcher=$!
  worker_appends "done [at=1700000300]: report ready"
  wait_for_mirrored "done [at=1700000300]: report ready" "the scout's terminal line"
  wait "$watcher" 2>/dev/null || true
  assert_absent "$early" "the scout's terminal line reached this home before its report"
  cmp -s "$report" "$PRIMARY/data/$ID/report.md" || fail "the local report is not the scout's report, byte for byte"
  signal_pending || fail "the scout's terminal line is invisible to the watcher's signal scan"
  assert_no_grep 'did not transfer' "$PRIMARY/state/$ID.status" "a delivered report left a transfer note"
  grep -q "^alias-$ID fm-remote-file.sh get$" "$CASE/ssh.log" || fail "the report was not read through the confined reader"
  pass "a sandbox scout's report is fetched into this home before its terminal line lands"
}

test_ship_decision_steer_peek_and_state
test_scout_report_lands_before_its_terminal_line
