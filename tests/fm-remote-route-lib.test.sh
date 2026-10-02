#!/usr/bin/env bash
# tests/fm-remote-route-lib.test.sh - remote dispatch (bin/fm-remote-route-lib.sh).
#
# The resolver cases drive the library's public functions against fixture task
# records: local records, legacy remote-secondmate records, valid sandbox task
# records, and every malformed or contradictory placement the strict form
# refuses. The consumer cases run the real fm-peek.sh, fm-send.sh,
# fm-control.sh, fm-teardown.sh, and fm-crew-state.sh, the secondmate liveness
# probe, and the watcher's foreign-queue stall tick against a home that holds a
# sandbox task record, with a logging ssh, tmux, and herdr first on PATH. Each
# consumer refuses with the library's named reason, reaches neither the remote
# transport nor a local backend, and leaves the record byte-identical, so a
# sandbox task can never fall into secondmate-only code or be read as local.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-route-lib)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-route-lib.sh"

RECORDS="$TMP_ROOT/records"
mkdir -p "$RECORDS"

# write_task_record <path> [key=value overrides...]: a complete, valid sandbox
# ship record for the task named by the file; an override replaces its key, and
# an override of the form "-key" drops it.
write_task_record() {
  local path=$1 id line key kept drop
  shift
  id=${path##*/}
  id=${id%.meta}
  {
    printf '%s\n' "window=remote:$id" "endpoint_task_id=$id" \
      "worktree=/home/agent/fm-home/projects/alpha-wt" "project=/primary/projects/alpha" \
      "harness=pi" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s1.1.1" \
      "placement=sandbox" "remote_kind=task" "remote_host=sbx-$id" \
      "remote_root=/opt/firstmate" "remote_home=/home/agent/fm-home" \
      "remote_backend=tmux" "remote_target=firstmate:fm-$id" \
      "sandbox_provider=pve-sandbox" "sandbox_name=sbx-home-$id" "sandbox_profile=default"
  } > "$path.base"
  : > "$path"
  while IFS= read -r line; do
    key=${line%%=*}
    kept=1
    for drop in "$@"; do
      case "$drop" in
        "-$key"|"$key="*) kept=0 ;;
      esac
    done
    [ "$kept" -eq 0 ] || printf '%s\n' "$line" >> "$path"
  done < "$path.base"
  rm -f "$path.base"
  for drop in "$@"; do
    case "$drop" in -*) ;; *) printf '%s\n' "$drop" >> "$path" ;; esac
  done
}

# expect_invalid <meta> <needle> <label> [task-id]
expect_invalid() {
  local meta=$1 needle=$2 label=$3 rc
  fm_remote_route_resolve "$meta" ${4:+"$4"}; rc=$?
  expect_code 1 "$rc" "$label"
  assert_equals invalid "$FM_REMOTE_ROUTE_KIND" "$label kind"
  assert_contains "$FM_REMOTE_ROUTE_ERROR" "$needle" "$label reason"
  assert_equals '' "$FM_REMOTE_ROUTE_HOST$FM_REMOTE_ROUTE_ROOT$FM_REMOTE_ROUTE_HOME$FM_REMOTE_ROUTE_CONTROL" \
    "$label must not leave a route behind"
}

# --- resolver: local and legacy records ---------------------------------------

test_absent_and_local_records_are_not_remote() {
  local rc
  fm_remote_route_resolve "$RECORDS/missing.meta"; rc=$?
  expect_code 0 "$rc" "an absent record"
  assert_equals none "$FM_REMOTE_ROUTE_KIND" "an absent record is not remote"
  fm_remote_route_resolve ''; rc=$?
  expect_code 0 "$rc" "an empty record path"
  assert_equals none "$FM_REMOTE_ROUTE_KIND" "an empty record path is not remote"
  fm_write_meta "$RECORDS/local.meta" "window=fm-local" "kind=ship" "worktree=$TMP_ROOT/wt"
  fm_remote_route_resolve "$RECORDS/local.meta"; rc=$?
  expect_code 0 "$rc" "a local record"
  assert_equals none "$FM_REMOTE_ROUTE_KIND" "a local record is not remote"
  assert_equals '' "$FM_REMOTE_ROUTE_CONTROL" "a local record names no control script"
  fm_write_meta "$RECORDS/explicit-local.meta" "window=fm-explicit-local" "kind=scout" "placement=local"
  fm_remote_route_resolve "$RECORDS/explicit-local.meta"; rc=$?
  expect_code 0 "$rc" "an explicit local placement"
  assert_equals none "$FM_REMOTE_ROUTE_KIND" "placement=local is not remote"
  pass "absent, local, and explicitly local records resolve to none"
}

test_legacy_remote_secondmate_keeps_its_signal() {
  local rc
  fm_write_meta "$RECORDS/rsm.meta" "window=remote:rsm" "endpoint_task_id=rsm" \
    "worktree=/remote/home" "kind=secondmate" "mode=secondmate" "home=/remote/home" \
    "remote_host=remote-mac" "remote_root=/remote/root" "remote_backend=herdr"
  fm_remote_route_resolve "$RECORDS/rsm.meta"; rc=$?
  expect_code 0 "$rc" "a legacy remote secondmate"
  assert_equals secondmate "$FM_REMOTE_ROUTE_KIND" "remote_host on a secondmate still marks a remote secondmate"
  assert_equals remote-mac "$FM_REMOTE_ROUTE_HOST" "the secondmate route host"
  assert_equals /remote/root "$FM_REMOTE_ROUTE_ROOT" "the secondmate code root"
  assert_equals /remote/home "$FM_REMOTE_ROUTE_HOME" "the secondmate home comes from home="
  assert_equals fm-remote-secondmate-control.sh "$FM_REMOTE_ROUTE_CONTROL" "the secondmate control script"
  pass "a legacy remote secondmate record resolves exactly as the remote_host signal did"
}

test_remote_host_outside_a_secondmate_is_refused() {
  fm_write_meta "$RECORDS/stray.meta" "window=remote:stray" "kind=ship" "remote_host=remote-mac"
  expect_invalid "$RECORDS/stray.meta" "valid only for a secondmate" "remote_host on a ship"
  fm_write_meta "$RECORDS/kindless.meta" "window=remote:kindless" "remote_host=remote-mac"
  expect_invalid "$RECORDS/kindless.meta" "valid only for a secondmate" "remote_host with no kind"
  pass "a remote_host record that is not a secondmate is refused, never routed as one"
}

# --- resolver: sandbox task records ------------------------------------------

test_sandbox_task_record_resolves_to_a_task_route() {
  local rc
  write_task_record "$RECORDS/t1.meta"
  fm_remote_route_resolve "$RECORDS/t1.meta"; rc=$?
  expect_code 0 "$rc" "a valid sandbox ship"
  assert_equals task "$FM_REMOTE_ROUTE_KIND" "a sandbox ship is a task route"
  assert_equals sbx-t1 "$FM_REMOTE_ROUTE_HOST" "the task route host"
  assert_equals /opt/firstmate "$FM_REMOTE_ROUTE_ROOT" "the task code root"
  assert_equals /home/agent/fm-home "$FM_REMOTE_ROUTE_HOME" "the task home comes from remote_home="
  assert_equals fm-remote-task-control.sh "$FM_REMOTE_ROUTE_CONTROL" "the task control script"
  write_task_record "$RECORDS/s1.meta" "kind=scout"
  fm_remote_route_resolve "$RECORDS/s1.meta"; rc=$?
  expect_code 0 "$rc" "a valid sandbox scout"
  assert_equals task "$FM_REMOTE_ROUTE_KIND" "a sandbox scout is a task route"
  # A captured copy named after something else is bound by the explicit id.
  cp "$RECORDS/t1.meta" "$RECORDS/captured-copy.meta"
  fm_remote_route_resolve "$RECORDS/captured-copy.meta" t1; rc=$?
  expect_code 0 "$rc" "a captured copy with its explicit task id"
  assert_equals task "$FM_REMOTE_ROUTE_KIND" "the explicit task id binds a captured copy"
  expect_invalid "$RECORDS/captured-copy.meta" "window=remote:captured-copy" \
    "a captured copy resolved by its own basename"
  # Fields from one resolution never leak into the next.
  fm_remote_route_resolve "$RECORDS/t1.meta" >/dev/null
  fm_remote_route_resolve "$RECORDS/local.meta"; rc=$?
  assert_equals none "$FM_REMOTE_ROUTE_KIND" "a later local resolution"
  assert_equals '' "$FM_REMOTE_ROUTE_HOST$FM_REMOTE_ROUTE_CONTROL" "a later local resolution keeps no task route"
  pass "a complete sandbox ship or scout record resolves to a validated task route"
}

test_sandbox_placement_must_be_explicit_and_consistent() {
  write_task_record "$RECORDS/no-kind.meta" "-remote_kind"
  expect_invalid "$RECORDS/no-kind.meta" "remote_kind=task" "placement=sandbox without remote_kind"
  write_task_record "$RECORDS/other-kind.meta" "remote_kind=secondmate"
  expect_invalid "$RECORDS/other-kind.meta" "remote_kind=task" "an unknown remote_kind"
  write_task_record "$RECORDS/inferred.meta" "-placement"
  expect_invalid "$RECORDS/inferred.meta" "placement= exactly once" "remote_kind=task without placement"
  write_task_record "$RECORDS/twice.meta" "placement=sandbox"
  printf 'placement=sandbox\n' >> "$RECORDS/twice.meta"
  expect_invalid "$RECORDS/twice.meta" "placement= exactly once" "a repeated placement"
  write_task_record "$RECORDS/vm.meta" "placement=vm"
  expect_invalid "$RECORDS/vm.meta" "unknown placement 'vm'" "an unknown placement"
  write_task_record "$RECORDS/mixed.meta" "placement=local"
  expect_invalid "$RECORDS/mixed.meta" "placement=local together with a remote route" "placement=local with a route"
  write_task_record "$RECORDS/mate.meta" "kind=secondmate"
  expect_invalid "$RECORDS/mate.meta" "only for one kind=ship or kind=scout" "a sandbox secondmate"
  write_task_record "$RECORDS/kindless-task.meta" "-kind"
  expect_invalid "$RECORDS/kindless-task.meta" "only for one kind=ship or kind=scout" "a sandbox record with no kind"
  write_task_record "$RECORDS/wrong-window.meta" "window=fm-wrong-window"
  expect_invalid "$RECORDS/wrong-window.meta" "window=remote:wrong-window" "a sandbox record with a local window"
  write_task_record "$RECORDS/wrong-binding.meta" "endpoint_task_id=other"
  expect_invalid "$RECORDS/wrong-binding.meta" "endpoint_task_id=wrong-binding" "a sandbox record bound to another task"
  write_task_record "$RECORDS/no-home.meta" "-remote_home"
  expect_invalid "$RECORDS/no-home.meta" "remote_home= exactly once" "a sandbox record with no remote home"
  write_task_record "$RECORDS/two-hosts.meta"
  printf 'remote_host=sbx-other\n' >> "$RECORDS/two-hosts.meta"
  expect_invalid "$RECORDS/two-hosts.meta" "remote_host=, remote_root=, and remote_home= exactly once" \
    "a sandbox record with two hosts"
  pass "sandbox placement is never inferred and refuses every contradictory record"
}

test_sandbox_route_shape_and_disjointness() {
  write_task_record "$RECORDS/opt-host.meta" "remote_host=-oProxyCommand=evil"
  expect_invalid "$RECORDS/opt-host.meta" "configured SSH alias is unsafe" "an option-shaped alias"
  write_task_record "$RECORDS/shell-host.meta" 'remote_host=sbx;touch'
  expect_invalid "$RECORDS/shell-host.meta" "configured SSH alias is unsafe" "a shell-shaped alias"
  write_task_record "$RECORDS/rel-root.meta" "remote_root=opt/firstmate"
  expect_invalid "$RECORDS/rel-root.meta" "remote root is not absolute" "a relative code root"
  write_task_record "$RECORDS/rel-home.meta" "remote_home=fm-home"
  expect_invalid "$RECORDS/rel-home.meta" "remote home is not absolute" "a relative home"
  write_task_record "$RECORDS/dots.meta" "remote_home=/home/agent/../root"
  expect_invalid "$RECORDS/dots.meta" "traversal components" "a home with traversal"
  write_task_record "$RECORDS/empty-part.meta" "remote_root=/opt//firstmate"
  expect_invalid "$RECORDS/empty-part.meta" "empty path component" "a root with an empty component"
  write_task_record "$RECORDS/same.meta" "remote_home=/opt/firstmate"
  expect_invalid "$RECORDS/same.meta" "overlapping remote root and home" "an identical root and home"
  write_task_record "$RECORDS/home-in-root.meta" "remote_home=/opt/firstmate/home"
  expect_invalid "$RECORDS/home-in-root.meta" "remote home inside its code root" "a home inside the root"
  write_task_record "$RECORDS/root-in-home.meta" "remote_root=/home/agent/fm-home/firstmate"
  expect_invalid "$RECORDS/root-in-home.meta" "remote code root inside its home" "a root inside the home"
  write_task_record "$RECORDS/prefix-sibling.meta" "remote_home=/opt/firstmate-home"
  fm_remote_route_resolve "$RECORDS/prefix-sibling.meta" >/dev/null
  assert_equals task "$FM_REMOTE_ROUTE_KIND" "a sibling that merely shares a prefix is disjoint"
  pass "a sandbox route must be safe, absolute, clean, and disjoint"
}

test_shape_check_and_refusal_wording() {
  local msg
  fm_remote_route_check_shape remote-mac /srv/fm /srv/home || fail "a clean route failed the shape check"
  fm_remote_route_check_shape remote-mac /srv/fm srv/home && fail "a relative home passed the shape check"
  assert_contains "$FM_REMOTE_ROUTE_ERROR" "configured remote home is not absolute: srv/home" "the shape refusal names the field"
  fm_remote_route_check_shape '' /srv/fm /srv/home && fail "an empty alias passed the shape check"
  fm_remote_route_check_shape remote-mac /srv/fm $'/srv/ho\tme' && fail "a control character passed the shape check"
  assert_contains "$FM_REMOTE_ROUTE_ERROR" "control characters" "the control-character refusal"
  write_task_record "$RECORDS/t1.meta"
  fm_remote_route_resolve "$RECORDS/t1.meta" >/dev/null
  msg=$(fm_remote_route_unsupported t1 "reading its pane")
  assert_contains "$msg" "task t1 runs in a sandbox on sbx-t1" "the refusal names the task and its host"
  assert_contains "$msg" "reading its pane is not supported for a sandbox task" "the refusal names the action"
  assert_contains "$msg" "refused rather than treated as local or as a remote secondmate" "the refusal says what did not happen"
  pass "the shape check and the unsupported-verb refusal speak for every consumer"
}

# --- consumers: a sandbox task record is refused everywhere --------------------

HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects/alpha"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALL_LOG="$TMP_ROOT/transport-calls.log"
: > "$CALL_LOG"
for tool in ssh tmux herdr; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALL_LOG"
exit 1
SH
  chmod +x "$FAKEBIN/$tool"
done
write_task_record "$STATE_DIR/t1.meta" "project=$HOME_DIR/projects/alpha"
TASK_SUM=$(cksum < "$STATE_DIR/t1.meta")

# run_consumer <script> [args...]: run one real consumer against the fixture
# home, capturing merged output in OUT and its status in RC.
run_consumer() {
  local script=$1
  shift
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SSH_BIN="$FAKEBIN/ssh" FM_CREW_STATE_NO_FORGE=1 \
    "$ROOT/bin/$script" "$@" 2>&1)
  RC=$?
}

assert_untouched() { # <label>
  [ ! -s "$CALL_LOG" ] || fail "$1 reached a transport or local backend:"$'\n'"$(cat "$CALL_LOG")"
  assert_equals "$TASK_SUM" "$(cksum < "$STATE_DIR/t1.meta")" "$1 changed the sandbox task record"
  assert_absent "$STATE_DIR/t1.inbox" "$1 created a steering inbox for the sandbox task"
}

test_peek_refuses_a_sandbox_task() {
  run_consumer fm-peek.sh t1
  expect_code 1 "$RC" "peek of a sandbox task by id"
  assert_contains "$OUT" "task t1 runs in a sandbox on sbx-t1; reading its pane is not supported" "peek names the refusal"
  run_consumer fm-peek.sh fm-t1
  expect_code 1 "$RC" "peek of a sandbox task by its fm- label"
  run_consumer fm-peek.sh remote:t1
  expect_code 1 "$RC" "peek of a sandbox task by its recorded window"
  assert_contains "$OUT" "reading its pane is not supported" "peek by window names the refusal"
  assert_untouched "peek"
  pass "fm-peek refuses a sandbox task by id, label, or recorded window"
}

test_send_refuses_a_sandbox_task() {
  run_consumer fm-send.sh t1 'please look at the failing test'
  expect_code 1 "$RC" "a steer to a sandbox task"
  assert_contains "$OUT" "steer not sent: task t1 runs in a sandbox on sbx-t1; steering it is not supported" "send names the refusal"
  run_consumer fm-send.sh t1 --key Enter
  expect_code 1 "$RC" "a key to a sandbox task"
  run_consumer fm-send.sh remote:t1 'typed at its window'
  expect_code 1 "$RC" "a typed steer at a sandbox task's recorded window"
  assert_contains "$OUT" "steering it is not supported" "send by window names the refusal"
  assert_untouched "send"
  pass "fm-send refuses a sandbox task before anything is recorded or typed"
}

test_control_refuses_a_sandbox_task() {
  local verb
  for verb in interrupt exit; do
    run_consumer fm-control.sh t1 "$verb"
    expect_code 1 "$RC" "control $verb of a sandbox task"
    assert_contains "$OUT" "task t1 runs in a sandbox on sbx-t1; lifecycle control is not supported" "control $verb names the refusal"
  done
  run_consumer fm-control.sh t1 relaunch --note 'recover'
  expect_code 1 "$RC" "control relaunch of a sandbox task"
  assert_not_contains "$OUT" "malformed" "a sandbox task is refused by placement, not as malformed metadata"
  assert_untouched "control"
  pass "fm-control refuses every lifecycle verb for a sandbox task"
}

test_teardown_refuses_a_sandbox_task() {
  run_consumer fm-teardown.sh t1
  expect_code 1 "$RC" "teardown of a sandbox task"
  assert_contains "$OUT" "REFUSED: task t1 runs in a sandbox on sbx-t1; teardown is not supported" "teardown names the refusal"
  assert_contains "$OUT" "nothing was changed" "teardown says nothing changed"
  run_consumer fm-teardown.sh t1 --force
  expect_code 1 "$RC" "forced teardown of a sandbox task"
  assert_contains "$OUT" "teardown is not supported" "forced teardown names the refusal"
  assert_untouched "teardown"
  assert_absent "$STATE_DIR/t1.backlog-close" "teardown recorded a backlog close for the sandbox task"
  pass "fm-teardown refuses a sandbox task, even forced, with nothing touched"
}

test_crew_state_reports_a_sandbox_task_unknown() {
  run_consumer fm-crew-state.sh t1
  expect_code 0 "$RC" "crew-state of a sandbox task"
  assert_contains "$OUT" "state: unknown · source: none · task t1 runs in a sandbox on sbx-t1; reading its current state is not supported" \
    "crew-state reports the sandbox task as unknown with the reason"
  assert_contains "$OUT" "(not proof of death)" "crew-state never calls the sandbox task dead"
  assert_not_contains "$OUT" "worktree gone" "crew-state must not probe the VM worktree locally"
  assert_untouched "crew-state"
  pass "fm-crew-state reports a sandbox task as unknown without probing it"
}

test_invalid_placement_is_refused_by_consumers() {
  fm_write_meta "$STATE_DIR/stray.meta" "window=remote:stray" "endpoint_task_id=stray" \
    "worktree=/remote/wt" "project=$HOME_DIR/projects/alpha" "kind=ship" "harness=claude" \
    "remote_host=remote-mac" "remote_root=/remote/root"
  run_consumer fm-peek.sh stray
  expect_code 1 "$RC" "peek of a ship carrying remote_host"
  assert_contains "$OUT" "valid only for a secondmate" "peek names the malformed placement"
  run_consumer fm-send.sh stray 'hello'
  expect_code 1 "$RC" "a steer to a ship carrying remote_host"
  assert_contains "$OUT" "valid only for a secondmate" "send names the malformed placement"
  run_consumer fm-crew-state.sh stray
  assert_contains "$OUT" "state: unknown · source: none · task stray records remote_host=remote-mac" \
    "crew-state names the malformed placement"
  run_consumer fm-control.sh stray interrupt
  expect_code 1 "$RC" "control of a ship carrying remote_host"
  assert_contains "$OUT" "valid only for a secondmate" "control names the malformed placement"
  run_consumer fm-teardown.sh stray
  expect_code 1 "$RC" "teardown of a ship carrying remote_host"
  assert_contains "$OUT" "valid only for a secondmate" "teardown names the malformed placement"
  assert_present "$STATE_DIR/stray.meta" "teardown removed a record it refused"
  [ ! -s "$CALL_LOG" ] || fail "a malformed placement reached a transport or local backend:"$'\n'"$(cat "$CALL_LOG")"
  rm -f "$STATE_DIR/stray.meta"
  pass "a ship carrying remote_host is refused, never routed as a remote secondmate"
}

test_liveness_probe_skips_non_secondmate_routes() {
  local out
  fm_write_meta "$STATE_DIR/sbx-mate.meta" "window=remote:sbx-mate" "endpoint_task_id=sbx-mate" \
    "kind=secondmate" "harness=claude" "placement=sandbox" "remote_kind=task" \
    "remote_host=sbx-mate" "remote_root=/opt/firstmate" "remote_home=/home/agent/fm-home"
  out=$(
    export PATH="$FAKEBIN:$PATH" FM_SSH_BIN="$FAKEBIN/ssh"
    # The sourced library reads its caller's STATE, as the watcher and
    # bootstrap provide it.
    # shellcheck disable=SC2034
    STATE="$STATE_DIR"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    fm_secondmate_liveness_probe "$STATE_DIR/sbx-mate.meta" sbx-mate poll
    printf '%s|%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    fm_secondmate_liveness_probe "$STATE_DIR/t1.meta" t1 poll
    printf '%s|%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
  )
  assert_contains "$out" "skipped|task sbx-mate records placement=sandbox, which is valid only for one kind=ship or kind=scout record" \
    "a sandbox-placed secondmate record is skipped with the library's reason"
  assert_contains "$out" "skipped|task t1 runs in a sandbox on sbx-t1; secondmate liveness recovery is not supported" \
    "a sandbox task never enters secondmate liveness recovery"
  rm -f "$STATE_DIR/sbx-mate.meta"
  assert_untouched "the liveness probe"
  pass "the secondmate liveness probe skips a sandbox task and a sandbox-placed secondmate"
}

test_watcher_stall_tick_reads_only_local_mate_queues() {
  local mates="$TMP_ROOT/mates" watch_state="$TMP_ROOT/watch-state" id
  mkdir -p "$watch_state"
  for id in local-mate bad-mate remote-mate; do
    mkdir -p "$mates/$id/state"
    printf '%s\n' "$id" > "$mates/$id/.fm-secondmate-home"
    printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$mates/$id/state/.wake-queue"
    fm_write_meta "$watch_state/$id.meta" "window=firstmate:fm-$id" "kind=secondmate" \
      "harness=claude" "backend=tmux" "home=$mates/$id"
  done
  printf 'placement=sandbox\n' >> "$watch_state/bad-mate.meta"
  printf 'remote_host=remote-mac\n' >> "$watch_state/remote-mate.meta"
  (
    export FM_STATE_OVERRIDE="$watch_state" FM_HOME="$TMP_ROOT/watch-home"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    secondmate_wake_stall_tick
  ) || fail "the watcher's stall tick failed"
  assert_present "$watch_state/.secondmate-wake-progress-local-mate" "a local mate's queue was not observed"
  assert_absent "$watch_state/.secondmate-wake-progress-bad-mate" "a malformed sandbox-placed record was read as a local mate"
  assert_absent "$watch_state/.secondmate-wake-progress-remote-mate" "a remote mate's queue was read locally"
  pass "the watcher's queue-stall tick reads only the queues remote dispatch calls local"
}

test_absent_and_local_records_are_not_remote
test_legacy_remote_secondmate_keeps_its_signal
test_remote_host_outside_a_secondmate_is_refused
test_sandbox_task_record_resolves_to_a_task_route
test_sandbox_placement_must_be_explicit_and_consistent
test_sandbox_route_shape_and_disjointness
test_shape_check_and_refusal_wording
test_peek_refuses_a_sandbox_task
test_send_refuses_a_sandbox_task
test_control_refuses_a_sandbox_task
test_teardown_refuses_a_sandbox_task
test_crew_state_reports_a_sandbox_task_unknown
test_invalid_placement_is_refused_by_consumers
test_liveness_probe_skips_non_secondmate_routes
test_watcher_stall_tick_reads_only_local_mate_queues

echo "ALL TESTS PASSED"
