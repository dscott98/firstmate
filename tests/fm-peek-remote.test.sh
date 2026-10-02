#!/usr/bin/env bash
# fm-peek remote-secondmate capture routing.
#
# A remote secondmate's pane lives on its own host. The old path resolved the
# meta's "remote:<id>" window through the local backend adapters and handed it
# to tmux, which failed with "can't find session: remote" - a healthy remote
# mate misreported as an unreadable endpoint. These tests drive the real
# fm-peek + fm-on executables with a stubbed ssh transport (FM_SSH_BIN seam)
# and a poisoned local tmux, pinning:
#   1. A remote selector routes the capture over the remote transport and
#      prints the remote pane tail; the local adapters are never consulted.
#   2. An unreachable host fails loudly naming the host, without claiming the
#      mate is dead.
#   3. A sandbox task selected by id or label routes the same way to its own
#      host's task control plane, an unreachable host fails loudly without a
#      death claim, and its recorded window is refused rather than read as a
#      local pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK="$ROOT/bin/fm-peek.sh"

TMP_ROOT=$(fm_test_tmproot fm-peek-remote)

# fake-ssh prints the canned remote capture; the poisoned tmux records any
# local read attempt so the "never consulted" property is a real assertion.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
if [ -n "${FM_FAKE_SSH_ARGV:-}" ]; then
  while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac; done
  { printf '%s ' "$1"; printf '%s' "${6:-}" | base64 --decode | tr '\0' ' '; printf '\n'; } >> "$FM_FAKE_SSH_ARGV"
fi
[ -z "${FM_FAKE_REMOTE_CAPTURE:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_CAPTURE"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux\n' >> "${FM_FAKE_TMUX_TOUCHED:?}"
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

setup_remote_home() {  # <name> -> echoes home dir with remote meta + registry
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

test_remote_peek_reads_remote_pane() {
  local dir fb home touched rc out
  dir="$TMP_ROOT/peek-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_remote_home peek-ok)
  touched="$dir/tmux-touched"; : > "$touched"

  out=$(env PATH="$fb:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$fb/fake-ssh" FM_FAKE_SSH_RC=0 \
    FM_FAKE_REMOTE_CAPTURE='● the remote mate is mid-refactor' \
    FM_FAKE_TMUX_TOUCHED="$touched" \
    "$PEEK" rsm 20 2>"$dir/err"); rc=$?
  expect_code 0 "$rc" "a healthy remote peek should succeed"
  assert_contains "$out" "the remote mate is mid-refactor" \
    "the remote pane tail should be printed"
  assert_not_contains "$out" "can't find session" \
    "a remote peek must not fall into a local session lookup"
  [ ! -s "$touched" ] || fail "the local tmux adapter was consulted for a remote target"
  pass "fm-peek remote: the capture routes over the remote transport, local adapters untouched"
}

test_remote_peek_unreachable_fails_loudly_without_death_claim() {
  local dir fb home touched rc err
  dir="$TMP_ROOT/peek-down"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_remote_home peek-down)
  touched="$dir/tmux-touched"; : > "$touched"

  env PATH="$fb:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$fb/fake-ssh" FM_FAKE_SSH_RC=255 \
    FM_FAKE_TMUX_TOUCHED="$touched" \
    "$PEEK" rsm >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "an unreachable remote peek must exit nonzero"
  assert_contains "$err" "remote pane of rsm on remote-mac" \
    "the failure must name the remote mate and host"
  assert_contains "$err" "not thereby dead" \
    "an unreadable remote pane must not be presented as a dead mate"
  pass "fm-peek remote: an unreachable host fails loudly without a false death claim"
}

setup_sandbox_home() {  # <name> -> echoes home dir with a sandbox task record
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/sbx.meta" \
    "window=remote:sbx" "endpoint_task_id=sbx" "worktree=/home/agent/fm-home/wt" \
    "harness=pi" "kind=ship" "mode=direct-PR" "yolo=off" "branch=fm/sbx" \
    "placement=sandbox" "remote_kind=task" "remote_host=sbx-host" \
    "remote_root=/opt/firstmate" "remote_home=/home/agent/fm-home" \
    "remote_backend=tmux" "remote_target=firstmate:fm-sbx" \
    "sandbox_provider=pve-sandbox" "sandbox_name=sbx-1" "sandbox_profile=default"
  printf '%s\n' "$home"
}

test_sandbox_peek_reads_the_task_host_pane() {
  local dir fb home touched rc out target
  dir="$TMP_ROOT/peek-sandbox"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_sandbox_home peek-sandbox)
  touched="$dir/tmux-touched"; : > "$touched"
  for target in sbx fm-sbx; do
    : > "$dir/argv"
    out=$(env PATH="$fb:$PATH" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_SSH_BIN="$fb/fake-ssh" FM_FAKE_SSH_RC=0 FM_FAKE_SSH_ARGV="$dir/argv" \
      FM_FAKE_REMOTE_CAPTURE='pi> running the sandbox suite' \
      FM_FAKE_TMUX_TOUCHED="$touched" \
      "$PEEK" "$target" 250 2>"$dir/err"); rc=$?
    expect_code 0 "$rc" "a healthy sandbox peek by $target should succeed"
    assert_contains "$out" "running the sandbox suite" "the sandbox pane tail should be printed"
    assert_equals "sbx-host fm-remote-task-control.sh capture sbx 100 " "$(cat "$dir/argv")" \
      "the capture crosses to the task's own host, clamped to the verb's 100-line cap"
  done
  [ ! -s "$touched" ] || fail "the local tmux adapter was consulted for a sandbox target"
  pass "fm-peek sandbox: a task selected by id or label reads its host pane, local adapters untouched"
}

test_sandbox_peek_unreachable_or_by_window_never_reads_locally() {
  local dir fb home touched rc err
  dir="$TMP_ROOT/peek-sandbox-down"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_sandbox_home peek-sandbox-down)
  touched="$dir/tmux-touched"; : > "$touched"
  env PATH="$fb:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$fb/fake-ssh" FM_FAKE_SSH_RC=255 \
    FM_FAKE_TMUX_TOUCHED="$touched" \
    "$PEEK" sbx >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "an unreachable sandbox peek must exit nonzero"
  assert_contains "$err" "could not read the sandbox pane of sbx on sbx-host" \
    "the failure must name the sandbox task and its host"
  assert_contains "$err" "the task is not thereby dead" \
    "an unreadable sandbox pane must not be presented as a dead task"
  : > "$dir/argv"
  env PATH="$fb:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$fb/fake-ssh" FM_FAKE_SSH_ARGV="$dir/argv" \
    FM_FAKE_TMUX_TOUCHED="$touched" \
    "$PEEK" remote:sbx >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a peek of a sandbox task's recorded window must exit nonzero"
  assert_contains "$err" "it is the recorded window of sandbox task sbx on sbx-host; peek the task by its id (sbx) instead" \
    "the window refusal names the task and the id to use"
  [ ! -s "$dir/argv" ] || fail "a refused window peek crossed the transport"
  [ ! -s "$touched" ] || fail "the local tmux adapter was consulted for a sandbox target"
  pass "fm-peek sandbox: an unreachable host fails loudly, and the recorded window is refused"
}

test_remote_peek_reads_remote_pane
test_remote_peek_unreachable_fails_loudly_without_death_claim
test_sandbox_peek_reads_the_task_host_pane
test_sandbox_peek_unreachable_or_by_window_never_reads_locally

echo "all fm-peek-remote tests passed"
