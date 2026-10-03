#!/usr/bin/env bash
# tests/fm-control-remote-task.test.sh - bin/fm-control.sh for a sandbox task:
# its lifecycle verbs run on the task's host, and a relaunch republishes this
# home's record from the identity the host confirms.
#
# The supervising home holds a sandbox task record and its canonical brief.
# The task's host is a real one-task home on this machine, provisioned and
# launched by the real host-side control plane (bin/fm-remote-task-control.sh)
# with fake tmux, treehouse, Pi, and no-mistakes. bin/fm-on.sh's FM_SSH_BIN
# seam is a fake ssh that decodes the fixed entrypoint's arguments and runs the
# named command from this checkout against that home under an empty
# environment, the way the remote job worker runs it, so the host's own
# fm-control.sh and fm-spawn.sh do the work. FM_TEST_HOST_BOOT_EPOCH (honored
# under FM_TEST_SEAM) stands in for the host's boot time to model a reboot, and
# a tripwire tmux on the supervising side records any local call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
HOST_CONTROL="$ROOT/bin/fm-remote-task-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-remote-task)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$

# Host-side spawns stage per-task temp roots at /tmp/fm-<id>, outside every
# fixture, so task ids carry this run's id and the roots are removed here.
cleanup() {
  rm -rf /tmp/fm-crt-*-"$RUN_ID" /tmp/fm-crt-*-"$RUN_ID"+* 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

b64() { base64 | tr -d '\n'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi
}

# --- fixtures ----------------------------------------------------------------

LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$LOCAL_BIN"
cat > "$LOCAL_BIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LOCAL_TMUX_LOG:?}"
exit 1
SH
chmod +x "$LOCAL_BIN/tmux"

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
# A tmux whose whole model is files under FM_FAKE_TMUX_DIR: server (the server
# runs), window (the one task window's name), pane-command (the pane's
# foreground process, the agent-state classifier's input), pane-path, and pane
# (capture). A typed /quit stops the agent; a launch brings Pi up.
cat > "$HOST_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_TMUX_DIR:?}
printf '%s\n' "$*" >> "$d/log"
case "$*" in
  *"#{pane_current_path}"*) cat "$d/pane-path" 2>/dev/null; exit 0 ;;
  *"#{pane_tty}"*) printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*) cat "$d/pane-command" 2>/dev/null || printf 'bash\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
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
    printf 'bash\n' > "$d/pane-command"
    printf '@1\n'
    ;;
  kill-window) rm -f "$d/window" ;;
  capture-pane) cat "$d/pane" 2>/dev/null || printf 'fake pane line\n' ;;
  display-message) printf 'firstmate\n' ;;
  send-keys)
    case "$*" in
      *'/quit'*) printf 'bash\n' > "$d/pane-command" ;;
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

# The transport: every command runs from this checkout against the sandbox home
# under an empty environment, as the remote job worker runs it. The case's
# ssh-down file makes the host unreachable (SSH exit 255).
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
printf '%s %s %s\n' "$host" "${args[0]}" "${args[1]:-}" >> "$FM_FAKE_SSH_LOG"
if [ -e "$FM_FAKE_SSH_DOWN" ]; then
  echo "ssh: connect to host $host port 22: Connection refused" >&2
  exit 255
fi
[ "$host" = "$FM_FAKE_SSH_HOST" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
exec env -i PATH="$FM_FAKE_HOST_BIN:$PATH" HOME="$FM_FAKE_HOST_DIR/account" \
  TMPDIR="$FM_FAKE_HOST_DIR/tmp" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR= \
  FM_FAKE_TMUX_DIR="$FM_FAKE_HOST_DIR/tmux" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
  FM_TEST_HOST_BOOT_EPOCH="${FM_TEST_HOST_BOOT_EPOCH:-}" FM_CONTROL_POLL=0.1 \
  FM_CONTROL_SETTLE_WAIT=0.2 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=30 \
  "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$LOCAL_BIN/fake-ssh"

ORIGIN="$TMP_ROOT/alpha.git"
fm_git_init_commit "$TMP_ROOT/alpha-seed"
git init -q --bare "$ORIGIN"
git -C "$TMP_ROOT/alpha-seed" push -q "$ORIGIN" HEAD:refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
REGISTRY_LINE='- alpha [direct-PR] - alpha fixture (added 2026-10-01)'

# --- per-case homes --------------------------------------------------------------

# run_host <verb> [args...]: one host-side control verb against this case's
# sandbox home, as the job worker runs it.
run_host() {
  env -i PATH="$HOST_BIN:$PATH" HOME="$HOST_DIR/account" TMPDIR="$HOST_DIR/tmp" \
    FM_HOME="$HOST_HOME" FM_ROOT_OVERRIDE="$ROOT" CLAUDE_CONFIG_DIR= \
    FM_FAKE_TMUX_DIR="$HOST_DIR/tmux" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
    "$HOST_CONTROL" "$@"
}

# run_primary <command...>: one supervising-home command with this case's
# transport; sets OUT (stdout and stderr) and RC.
run_primary() {
  OUT=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_ROOT_OVERRIDE -u TMUX -u TMUX_PANE \
    FM_HOME="$PRIMARY" PATH="$LOCAL_BIN:$PATH" FM_SSH_BIN="$LOCAL_BIN/fake-ssh" \
    FM_FAKE_SSH_HOST="alias-$ID" FM_FAKE_SSH_LOG="$CASE/ssh.log" FM_FAKE_SSH_DOWN="$CASE/ssh-down" \
    FM_FAKE_HOST_DIR="$HOST_DIR" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_LOCAL_TMUX_LOG="$CASE/local-tmux.log" FM_TEST_HOST_BOOT_EPOCH="${FM_TEST_HOST_BOOT_EPOCH:-}" \
    "$@" 2>&1)
  RC=$?
}

route_value() { # <block> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

meta_value() { # <key>
  sed -n "s/^$1=//p" "$PRIMARY/state/$ID.meta" | tail -n 1
}

# new_case <name>: a supervising home holding a sandbox ship's record and
# canonical brief, and that ship provisioned and running on its host. Sets
# CASE, ID, PRIMARY, HOST_DIR, HOST_HOME, WT, and SPAWN_GEN.
new_case() {
  local name=$1 scratch out
  CASE="$TMP_ROOT/$name"
  ID="crt-$name-$RUN_ID"
  PRIMARY="$CASE/primary"
  HOST_DIR="$CASE/host"
  HOST_HOME="$HOST_DIR/fm-home"
  WT="$HOST_DIR/wt"
  mkdir -p "$PRIMARY/data/$ID" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects/alpha" \
    "$HOST_DIR/tmp" "$HOST_DIR/tmux" "$HOST_DIR/account"
  scratch="$CASE/brief-scratch"
  mkdir -p "$scratch/data"
  FM_HOME="$scratch" "$ROOT/bin/fm-brief.sh" "$ID" alpha --mode direct-PR --for-home "$HOST_HOME" --for-root "$ROOT" >/dev/null \
    || fail "fm-brief.sh could not render the sandbox brief"
  sed -e 's/{TASK}/Make the sandbox change./' -e 's/{FIRSTMATE_SPEC}/Build only what the intent asks./' \
    "$scratch/data/$ID/brief.md" > "$PRIMARY/data/$ID/brief.md"
  {
    printf 'schema=fm-remote-task-provision.v1\n'
    printf 'task_id=%s\n' "$ID"
    printf 'kind=ship\n'
    printf 'project=alpha\n'
    printf 'origin_b64=%s\n' "$(printf 'file://%s' "$ORIGIN" | b64)"
    printf 'registry_b64=%s\n' "$(printf '%s' "$REGISTRY_LINE" | b64)"
    printf 'harness=pi\n'
    printf 'model=minimax/m2\n'
    printf 'effort=default\n'
    printf 'brief_b64=%s\n' "$(b64 < "$PRIMARY/data/$ID/brief.md")"
    printf 'mode=direct-PR\n'
    printf 'yolo=off\n'
    printf 'branch_prefix_b64=%s\n' "$(printf 'fm/' | b64)"
  } > "$CASE/manifest"
  out=$(run_host provision "$ID" < "$CASE/manifest" 2>&1) || fail "provisioning $ID failed: $out"
  git -C "$HOST_HOME/projects/alpha" worktree add -q --detach "$WT" >/dev/null 2>&1 \
    || fail "could not create the fixture task worktree"
  printf '%s\n' "$WT" > "$HOST_DIR/tmux/pane-path"
  out=$(run_host launch "$ID" 2>&1) || fail "launching $ID failed: $out"
  SPAWN_GEN=$(route_value "$out" spawn_gen)
  [ -n "$SPAWN_GEN" ] || fail "the host's launch reported no spawn_gen: $out"
  # Pi's empty composer, as the control plane must prove before typing /quit.
  printf '╭────╮\n│    │\n╰────╯\n' > "$HOST_DIR/tmux/pane"
  fm_write_meta "$PRIMARY/state/$ID.meta" "window=remote:$ID" "endpoint_task_id=$ID" "worktree=$WT" \
    "project=$PRIMARY/projects/alpha" "harness=pi" "kind=ship" "mode=direct-PR" "yolo=off" \
    "branch=fm/$ID" "tasktmp=" "model=minimax/m2" "effort=default" "spawn_gen=$SPAWN_GEN" \
    "placement=sandbox" "remote_kind=task" "remote_host=alias-$ID" "remote_root=$ROOT" \
    "remote_home=$HOST_HOME" "remote_backend=tmux" "remote_target=firstmate:fm-$ID" \
    "sandbox_provider=pve-sandbox" "sandbox_name=sbx-$ID" "sandbox_profile=default"
}

assert_no_local_backend() { # <label>
  [ ! -s "$CASE/local-tmux.log" ] || fail "$1 touched a local tmux:"$'\n'"$(cat "$CASE/local-tmux.log")"
}

ssh_calls() { # <verb>: how many host calls of fm-remote-task-control.sh <verb>
  grep -c "^alias-$ID fm-remote-task-control.sh $1\$" "$CASE/ssh.log" 2>/dev/null || true
}

# --- interrupt and exit ------------------------------------------------------

test_interrupt_and_exit_run_on_the_host() {
  local before
  new_case verbs
  cp "$PRIMARY/state/$ID.meta" "$CASE/meta.before"
  run_primary "$CONTROL" "$ID" interrupt
  expect_code 0 "$RC" "interrupt of a sandbox task"$'\n'"$OUT"
  assert_contains "$OUT" "interrupt-delivered $ID harness=pi backend=tmux" "interrupt relays the host's result"
  assert_equals 1 "$(ssh_calls control)" "interrupt crossed to the host's control verb once"
  assert_grep "send-keys -t firstmate:fm-$ID Escape" "$HOST_DIR/tmux/log" "the interrupt key reached the host's pane"

  run_primary "$CONTROL" "$ID" exit
  expect_code 0 "$RC" "exit of a sandbox task"$'\n'"$OUT"
  assert_contains "$OUT" "stopped $ID harness=pi backend=tmux" "exit relays the host's stop"
  assert_equals bash "$(cat "$HOST_DIR/tmux/pane-command")" "the host's agent stopped"
  run_primary "$CONTROL" "$ID" exit
  expect_code 0 "$RC" "a repeated exit is idempotent on the host"
  assert_contains "$OUT" "already-stopped $ID" "a repeated exit reports already-stopped"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "interrupt or exit changed this home's record"
  before=$(wc -l < "$CASE/ssh.log")
  : > "$CASE/ssh-down"
  run_primary "$CONTROL" "$ID" interrupt
  expect_code 255 "$RC" "an unreachable host returns SSH exit 255 unchanged"
  assert_contains "$OUT" "could not be reached (SSH exit 255), so whether its interrupt happened there is unknown" \
    "an unreachable host is unknown completion, never a claim"
  assert_equals $((before + 1)) "$(wc -l < "$CASE/ssh.log")" "an unreachable host is tried once"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "an unreachable host changed this home's record"
  assert_no_local_backend "interrupt and exit"
  pass "interrupt and exit run on a sandbox task's host, relay its result, and leave the record alone"
}

# --- relaunch: the host relaunches, this home republishes ------------------------

test_relaunch_republishes_from_the_host_confirmed_identity() {
  local out new_gen host_brief canonical_sha notes last_two field
  new_case relaunch
  printf 'pr=https://github.com/example/alpha/pull/7\npr_head=0123456789abcdef0123456789abcdef01234567\n' \
    >> "$PRIMARY/state/$ID.meta"
  canonical_sha=$(sha256_of "$PRIMARY/data/$ID/brief.md")
  mkdir -p "$PRIMARY/state/.sandbox-observe-$ID"
  printf 'agent=missing\nbusy=dead\nobserved_at=%s\n' "$(date +%s)" > "$PRIMARY/state/.sandbox-observe-$ID/last"
  printf '3 %s\n' "$(date +%s)" > "$PRIMARY/state/.sandbox-observe-$ID/failures"
  touch "$PRIMARY/state/.sandbox-observe-$ID/alerted" "$PRIMARY/state/.sandbox-observe-$ID/tick"

  run_primary "$CONTROL" "$ID" relaunch --note 'Resume from the committed rebase.'
  expect_code 0 "$RC" "relaunch of a sandbox task"$'\n'"$OUT"
  assert_equals 1 "$(ssh_calls brief-update)" "a record with no brief digest sends this home's brief first"
  new_gen=$(sed -n 's/^spawn_gen=//p' "$HOST_HOME/state/$ID.meta")
  [ -n "$new_gen" ] && [ "$new_gen" != "$SPAWN_GEN" ] || fail "the host did not relaunch a new incarnation"
  assert_equals "$new_gen" "$(meta_value spawn_gen)" "this home's record carries the host's new incarnation"
  for field in last failures alerted tick; do
    assert_absent "$PRIMARY/state/.sandbox-observe-$ID/$field" "the replacement cannot inherit $field from its predecessor"
  done
  assert_equals "$canonical_sha" "$(meta_value brief_sha256)" "the record names the brief the host holds"
  assert_equals pi "$(meta_value harness)" "the harness is republished from the host"
  assert_equals minimax/m2 "$(meta_value model)" "the model is republished from the host"
  assert_equals "firstmate:fm-$ID" "$(meta_value remote_target)" "the endpoint is republished from the host"
  assert_contains "$OUT" "republished $ID from its sandbox host alias-$ID" "relaunch reports the republish"
  last_two=$(tail -n 2 "$PRIMARY/state/$ID.meta")
  assert_equals "pr=https://github.com/example/alpha/pull/7"$'\n'"pr_head=0123456789abcdef0123456789abcdef01234567" \
    "$last_two" "the pr= identity block stays last in the republished record"
  assert_equals 1 "$(grep -c '^spawn_gen=' "$PRIMARY/state/$ID.meta")" "the record holds one spawn_gen"
  host_brief="$HOST_HOME/data/$ID/brief.md"
  assert_grep "Resume from the committed rebase." "$host_brief" "the host's brief carries the progress note"
  assert_equals pi "$(cat "$HOST_DIR/tmux/pane-command")" "the replacement agent runs on the host"

  # An unchanged brief is not sent again, so the host's progress notes stay.
  run_primary "$CONTROL" "$ID" relaunch --note 'Second resume.'
  expect_code 0 "$RC" "a second relaunch"$'\n'"$OUT"
  assert_equals 1 "$(ssh_calls brief-update)" "an unchanged brief is not sent again"
  notes=$(grep -c '^## Progress note' "$host_brief")
  assert_equals 2 "$notes" "the host's brief keeps both progress notes"

  # A changed brief is sent, replacing the host's copy before the relaunch.
  printf '\nAn added line of captain intent.\n' >> "$PRIMARY/data/$ID/brief.md"
  run_primary "$CONTROL" "$ID" relaunch --note 'Third resume.'
  expect_code 0 "$RC" "a relaunch after the brief changed"$'\n'"$OUT"
  assert_equals 2 "$(ssh_calls brief-update)" "a changed brief is sent before the relaunch"
  assert_grep "An added line of captain intent." "$host_brief" "the host relaunched from the changed brief"
  assert_equals 1 "$(grep -c '^## Progress note' "$host_brief")" "the sent brief carries only this relaunch's note"
  assert_equals "$(sha256_of "$PRIMARY/data/$ID/brief.md")" "$(meta_value brief_sha256)" "the record names the changed brief"
  assert_no_local_backend "relaunch"
  pass "relaunch runs on the host, sends a changed brief first, and republishes this home's record from the host"
}

test_relaunch_refuses_what_the_sandbox_cannot_run() {
  new_case refuse
  cp "$PRIMARY/state/$ID.meta" "$CASE/meta.before"
  run_primary "$CONTROL" "$ID" relaunch
  expect_code 1 "$RC" "a relaunch without a note"
  assert_contains "$OUT" "requires --note" "the missing note is named"
  run_primary "$CONTROL" "$ID" relaunch --harness codex --note 'switch'
  expect_code 1 "$RC" "a relaunch onto another harness"
  assert_contains "$OUT" "provisioned with credentials for harness pi only" "the credential boundary is named"
  run_primary "$CONTROL" "$ID" relaunch --harness claude --note 'switch'
  expect_code 1 "$RC" "a relaunch onto Claude"
  run_primary "$CONTROL" "$ID" relaunch --model openai/gpt --note 'switch'
  expect_code 1 "$RC" "a relaunch onto another Pi provider"
  assert_contains "$OUT" "holds only the credential for Pi provider minimax" "the provider boundary is named"
  run_primary "$CONTROL" "$ID" relaunch --model default --note 'switch'
  expect_code 1 "$RC" "a relaunch onto a Pi model naming no provider"
  [ ! -s "$CASE/ssh.log" ] || fail "a refused relaunch reached the host:"$'\n'"$(cat "$CASE/ssh.log")"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "a refused relaunch changed the record"

  # A host that cannot be reached is unknown completion, and leaves the record.
  : > "$CASE/ssh-down"
  run_primary "$CONTROL" "$ID" relaunch --note 'resume'
  expect_code 255 "$RC" "a relaunch whose brief cannot reach the host"
  assert_contains "$OUT" "the relaunch was not started and its agent is untouched" "the unsent brief stops the relaunch"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "an unreachable host changed the record"
  assert_equals 0 "$(ssh_calls control)" "nothing past the unsent brief reached the host"
  assert_no_local_backend "refused relaunches"
  pass "relaunch refuses, before its host, a note-less, cross-harness, or cross-provider replacement"
}

# --- after a reboot: the host's boot-time absence proof ---------------------------

# reboot_host: the VM restarted, so its tmux server and every window are gone
# while its disk - the home, worktree, and brief - survives.
reboot_host() {
  rm -f "$HOST_DIR/tmux/server" "$HOST_DIR/tmux/window"
  printf 'bash\n' > "$HOST_DIR/tmux/pane-command"
}

test_a_rebooted_host_relaunches_from_its_brief() {
  local spawn_epoch new_gen
  new_case reboot
  spawn_epoch=${SPAWN_GEN#s}
  spawn_epoch=${spawn_epoch%%.*}
  reboot_host

  # Without a reboot since the launch, a missing tmux endpoint stays unproven.
  cp "$PRIMARY/state/$ID.meta" "$CASE/meta.before"
  FM_TEST_HOST_BOOT_EPOCH=$((spawn_epoch - 60)) run_primary "$CONTROL" "$ID" relaunch --note 'recover'
  expect_code 1 "$RC" "a relaunch the host cannot prove absent"
  assert_contains "$OUT" "is not after the launch of the recorded endpoint" "the refusal names the missing proof"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "a refused relaunch changed this home's record"
  assert_absent "$HOST_DIR/tmux/window" "a refused relaunch created a window"

  # A host booted after the launch proves the endpoint gone.
  FM_TEST_HOST_BOOT_EPOCH=$((spawn_epoch + 60)) run_primary "$CONTROL" "$ID" exit
  expect_code 0 "$RC" "exit after the reboot"$'\n'"$OUT"
  assert_contains "$OUT" "endpoint-gone $ID" "exit reports the endpoint the reboot destroyed"

  FM_TEST_HOST_BOOT_EPOCH=$((spawn_epoch + 60)) run_primary "$CONTROL" "$ID" relaunch --note 'The VM rebooted; resume.'
  expect_code 0 "$RC" "relaunch after the reboot"$'\n'"$OUT"
  assert_equals "fm-$ID" "$(cat "$HOST_DIR/tmux/window")" "the window is re-created under its recorded name"
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-$ID -c $WT" "$HOST_DIR/tmux/log" \
    "the window is re-created in the recorded worktree"
  assert_equals pi "$(cat "$HOST_DIR/tmux/pane-command")" "the replacement agent runs on the host"
  new_gen=$(sed -n 's/^spawn_gen=//p' "$HOST_HOME/state/$ID.meta")
  assert_equals "$new_gen" "$(meta_value spawn_gen)" "this home's record carries the reclaimed incarnation"
  assert_grep "The VM rebooted; resume." "$HOST_HOME/data/$ID/brief.md" "the replacement is briefed from the brief on disk"
  assert_no_local_backend "the reboot recovery"
  pass "a rebooted host proves its endpoint gone, so exit reports it and relaunch re-creates it from the brief"
}

# --- this home's own spawn never relaunches a sandbox task ------------------------

test_spawn_relaunch_points_at_the_control_plane() {
  new_case spawn
  cp "$PRIMARY/state/$ID.meta" "$CASE/meta.before"
  run_primary "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch
  expect_code 1 "$RC" "this home's spawn --relaunch of a sandbox task"
  assert_contains "$OUT" "use bin/fm-control.sh $ID relaunch" "the refusal names the control plane"
  cmp -s "$CASE/meta.before" "$PRIMARY/state/$ID.meta" || fail "a refused spawn relaunch changed the record"
  [ ! -s "$CASE/ssh.log" ] || fail "a refused spawn relaunch reached the host"
  pass "this home's spawn --relaunch refuses a sandbox task and names fm-control"
}

test_interrupt_and_exit_run_on_the_host
test_relaunch_republishes_from_the_host_confirmed_identity
test_relaunch_refuses_what_the_sandbox_cannot_run
test_a_rebooted_host_relaunches_from_its_brief
test_spawn_relaunch_points_at_the_control_plane
echo "ALL TESTS PASSED"
