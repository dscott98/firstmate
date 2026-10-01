#!/usr/bin/env bash
# Behavior tests for bin/fm-sandbox.sh, the provider-neutral sandbox adapter.
#
# Drives the public argv interface with a fake provider that records the exact
# argv it received (one ARG: line per element) and answers from control files
# (out, err, rc). The fake provider's directory name contains a space, so
# every passing case also proves the provider path is executed as one argv
# element rather than shell-split. Cases cover the PR1 contract: default-off
# refusal without config, config parsing, create output validation (missing
# and unknown keys, malformed lines, hostkey pinning), status and policy
# passthrough, list filtering by the fm_home label, label-mismatch and
# absent-is-success destroy, capacity-refusal distinguishability, and
# argv-only invocation (no shell interpolation of names or exec arguments).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-sandbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox)
HOME_DIR="$TMP_ROOT/home"
CTRL="$TMP_ROOT/ctrl"
PROVIDER_DIR="$TMP_ROOT/fake provider dir"
PROVIDER="$PROVIDER_DIR/fake-provider.sh"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
ARGV_LOG="$CTRL/argv.log"
PWN="$TMP_ROOT/pwned"
mkdir -p "$HOME_DIR" "$CTRL" "$PROVIDER_DIR"

cat > "$PROVIDER" <<'SH'
#!/usr/bin/env bash
# fake sandbox provider: records argv, captures --home, answers from files
set -u
CTRL_DIR=${FAKE_CTRL_DIR:?FAKE_CTRL_DIR must be set}
printf 'ARG:%s\n' "$@" >> "$CTRL_DIR/argv.log"
if [ "$#" -gt 0 ]; then
  shift
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--home" ] && [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" > "$CTRL_DIR/home-seen"
  fi
  shift
done
if [ -f "$CTRL_DIR/out" ]; then
  cat "$CTRL_DIR/out"
fi
if [ -f "$CTRL_DIR/err" ]; then
  cat "$CTRL_DIR/err" >&2
fi
if [ -f "$CTRL_DIR/rc" ]; then
  exit "$(cat "$CTRL_DIR/rc")"
fi
exit 0
SH
chmod +x "$PROVIDER"

set_fake() {
  printf '%s' "${1:-0}" > "$CTRL/rc"
  printf '%s' "${2:-}" > "$CTRL/err"
  printf '%s' "${3:-}" > "$CTRL/out"
}

write_config() {
  cat > "$HOME_DIR/config/sandbox-provider" <<EOF
$PROVIDER
default_profile=${1:-default}
ttl=${2:-4h}
ssh_include=$HOME_DIR/ssh-includes
EOF
}

run() {
  FM_HOME="$HOME_DIR" FAKE_CTRL_DIR="$CTRL" "$TOOL" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

reset_argv_log() {
  : > "$ARGV_LOG"
}

argv_has() {
  grep -qxF "ARG:$1" "$ARGV_LOG" || fail "provider argv missing '$1'"
}

# --- default-off: no config means every request refuses ----------------------

while IFS= read -r args; do
  # shellcheck disable=SC2086
  run $args
  [ "$RC" -eq 3 ] || fail "without config, '$args' must refuse with exit 3, got $RC"
  grep -q "config/sandbox-provider" "$ERR" || fail "without config, '$args' must name the missing config file"
done <<'CASES'
create t1
status sbx-1
list
extend sbx-1
hold sbx-1
release sbx-1
policy sbx-1
exec sbx-1 -- true
snapshot sbx-1 snap1
rollback sbx-1 snap1
destroy sbx-1 --expect-task t1
CASES
[ ! -e "$HOME_DIR/state" ] || fail "without config, a refusal must not create state"
pass "ok - without config every verb refuses (exit 3) and nothing else changes"

run --help
[ "$RC" -eq 0 ] || fail "--help must work without config, got $RC"
grep -q "usage:" "$OUT" || fail "--help must print usage"
pass "ok - --help works without config"

# --- usage errors (exit 2) ----------------------------------------------------

run
[ "$RC" -eq 2 ] || fail "no verb must be a usage error, got $RC"
run bogus
[ "$RC" -eq 2 ] || fail "unknown verb must be a usage error, got $RC"
run create
[ "$RC" -eq 2 ] || fail "create without a task id must be a usage error, got $RC"
run status
[ "$RC" -eq 2 ] || fail "status without a name must be a usage error, got $RC"
run status "sbx 1"
[ "$RC" -eq 2 ] || fail "a name with whitespace must be a usage error, got $RC"
run status -x
[ "$RC" -eq 2 ] || fail "a name with a leading dash must be a usage error, got $RC"
run status "a=b"
[ "$RC" -eq 2 ] || fail "a name containing '=' must be a usage error, got $RC"
run exec sbx-1 true
[ "$RC" -eq 2 ] || fail "exec without '--' must be a usage error, got $RC"
run exec sbx-1 --
[ "$RC" -eq 2 ] || fail "exec with an empty command argv must be a usage error, got $RC"
run destroy sbx-1
[ "$RC" -eq 2 ] || fail "destroy without --expect-task must be a usage error, got $RC"
run create t1 --ttl forever
[ "$RC" -eq 2 ] || fail "a malformed --ttl must be a usage error, got $RC"
run create t1 --profile -open
[ "$RC" -eq 2 ] || fail "a profile with a leading dash must be a usage error, got $RC"
run extend sbx-1 extra
[ "$RC" -eq 2 ] || fail "an unknown extend argument must be a usage error, got $RC"
pass "ok - malformed invocations are usage errors (exit 2)"

# --- config parsing refusals (exit 3) -----------------------------------------

mkdir -p "$HOME_DIR/config"
printf '%s\n' "relative/provider.sh" "default_profile=default" "ttl=4h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a relative provider path must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=4h" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a missing ssh_include key must be refused, got $RC"
printf '%s\n' "$PROVIDER" "ttl=4h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a missing default_profile key must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a missing ttl key must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=forever" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a malformed ttl must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=4h" "ssh_include=relative/path" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a relative ssh_include must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=4h" "ttl=8h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a duplicate key must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=4h" "ssh_include=/abs" "extra=1" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "an unknown key must be refused, got $RC"
printf '%s\n' "$PROVIDER" "default_profile=default" "ttl=4h" "ssh_include=/abs" "justtext" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a malformed config line must be refused, got $RC"
printf '%s\n' "# a comment first" "$PROVIDER" "default_profile=default" "ttl=4h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run list
[ "$RC" -eq 3 ] || fail "a comment on the first line must be refused: the path comes first, got $RC"
pass "ok - a malformed config is refused with the concrete problem"

# --- config parsing happy path ------------------------------------------------

write_config
set_fake 0 "" ""
run hold sbx-1
[ "$RC" -eq 0 ] || fail "a valid config must be accepted, got $RC (stderr: $(cat "$ERR"))"
pass "ok - a valid config with comments and blank lines is accepted"

# --- create -------------------------------------------------------------------

CREATE_OUT="name=sbx-tag-t1
vmid=101
node=pve1
ssh_alias=sbx-t1
user=agent
profile=default
ttl_expires=2026-10-05T12:00:00Z
hostkey=pinned"

reset_argv_log
set_fake 0 "" "$CREATE_OUT"
run create t1
[ "$RC" -eq 0 ] || fail "create must pass through a valid record, got $RC (stderr: $(cat "$ERR"))"
printf '%s\n' "$CREATE_OUT" | cmp -s - "$OUT" || fail "create stdout must equal the validated provider record"
TAG=$(cat "$CTRL/home-seen")
case "$TAG" in ''|*[[:space:]]*) fail "create must pass a non-empty whitespace-free home tag, got '$TAG'" ;; esac
argv_has create
argv_has t1
argv_has --home
argv_has "$TAG"
argv_has --profile
argv_has default
argv_has --ttl
argv_has 4h
pass "ok - create validates and passes through the eight-key record"

reset_argv_log
run create t2 --profile open --ttl 30m
[ "$RC" -eq 0 ] || fail "create with explicit flags must succeed, got $RC"
argv_has open
argv_has 30m
pass "ok - explicit --profile and --ttl override the config defaults"

set_fake 0 "" "name=sbx-tag-t1
vmid=101
node=pve1
ssh_alias=sbx-t1
user=agent
profile=default
ttl_expires=2026-10-05T12:00:00Z"
run create t1
[ "$RC" -eq 3 ] || fail "create output missing hostkey must be refused, got $RC"
set_fake 0 "" "name=sbx-tag-t1
vmid=101
node=pve1
ssh_alias=sbx-t1
user=agent
profile=default
ttl_expires=2026-10-05T12:00:00Z
hostkey=maybe"
run create t1
[ "$RC" -eq 3 ] || fail "hostkey must be exactly pinned, got $RC"
set_fake 0 "" "$CREATE_OUT
extra=1"
run create t1
[ "$RC" -eq 3 ] || fail "an unknown output key must be refused, got $RC"
set_fake 0 "" "$CREATE_OUT
name=sbx-again"
run create t1
[ "$RC" -eq 3 ] || fail "a duplicate output key must be refused, got $RC"
set_fake 0 "" "$CREATE_OUT
garbage line"
run create t1
[ "$RC" -eq 3 ] || fail "a malformed output line must be refused, got $RC"
printf '%s\n' "$CREATE_OUT" | sed 's/^user=agent$/user=/' > "$CTRL/out"
printf '%s' 0 > "$CTRL/rc"
run create t1
[ "$RC" -eq 3 ] || fail "an empty value must be refused, got $RC"
printf '%s\n' "$CREATE_OUT" | sed 's/^user=agent$/User=agent/' > "$CTRL/out"
run create t1
[ "$RC" -eq 3 ] || fail "a non-lowercase key must be refused, got $RC"
pass "ok - create refuses malformed, unknown, duplicate, and invalid output"

# --- status -------------------------------------------------------------------

STATUS_OUT="name=sbx-tag-t1
state=running
vmid=101
fm_task=t1
fm_home=$TAG"
set_fake 0 "" "$STATUS_OUT"
run status sbx-tag-t1
[ "$RC" -eq 0 ] || fail "status must pass through a valid record, got $RC"
printf '%s\n' "$STATUS_OUT" | cmp -s - "$OUT" || fail "status stdout must equal the validated provider record"
reset_argv_log
set_fake 0 "" "state=absent"
run status sbx-gone
[ "$RC" -eq 0 ] || fail "status of an absent sandbox must succeed, got $RC"
argv_has status
argv_has sbx-gone
set_fake 0 "" "name=sbx-tag-t1
vmid=101"
run status sbx-tag-t1
[ "$RC" -eq 3 ] || fail "status output missing state must be refused, got $RC"
set_fake 0 "" "name=sbx-tag-t1
state=sleeping"
run status sbx-tag-t1
[ "$RC" -eq 3 ] || fail "an unknown state value must be refused, got $RC"
pass "ok - status passes through state and labels, refuses missing or invalid state"

# --- list filtering ------------------------------------------------------------

LIST_OUT="name=sbx-a
state=running
fm_task=t1
fm_home=$TAG
name=sbx-b
state=stopped
fm_home=another-home-9999
name=sbx-c
state=running"
reset_argv_log
set_fake 0 "" "$LIST_OUT"
run list
[ "$RC" -eq 0 ] || fail "list must succeed on mixed records, got $RC (stderr: $(cat "$ERR"))"
printf 'name=sbx-a\nstate=running\nfm_task=t1\nfm_home=%s\n' "$TAG" | cmp -s - "$OUT" || fail "list must keep only this home's records, got: $(cat "$OUT")"
argv_has list
argv_has --home
argv_has "$TAG"
TAG2=$(cat "$CTRL/home-seen")
[ "$TAG2" = "$TAG" ] || fail "list must use the same home tag as create ($TAG2 vs $TAG)"
pass "ok - list filters records by the fm_home label and stays on one home tag"

set_fake 0 "" "name=sbx-a
fm_home=$TAG"
run list
[ "$RC" -eq 3 ] || fail "a list record missing state must be refused, got $RC"
set_fake 0 "" "state=running
name=sbx-a
fm_home=$TAG"
run list
[ "$RC" -eq 3 ] || fail "a list record not starting with name= must be refused, got $RC"
set_fake 0 "" "name=sbx-a
state=running
state=stopped
fm_home=$TAG"
run list
[ "$RC" -eq 3 ] || fail "a duplicate key inside one list record must be refused, got $RC"
set_fake 0 "" ""
run list
[ "$RC" -eq 0 ] || fail "an empty list must succeed with no output, got $RC"
[ ! -s "$OUT" ] || fail "an empty list must print nothing"
pass "ok - list refuses malformed records and accepts an empty list"

# --- extend, hold, release, policy, snapshot, rollback --------------------------

reset_argv_log
set_fake 0 "" ""
run extend sbx-a
[ "$RC" -eq 0 ] || fail "extend must succeed with empty provider output, got $RC"
argv_has extend
argv_has sbx-a
argv_has --ttl
argv_has 4h
reset_argv_log
run extend sbx-a --ttl 2h
[ "$RC" -eq 0 ] || fail "extend with an explicit ttl must succeed, got $RC"
argv_has 2h
run hold sbx-a
[ "$RC" -eq 0 ] || fail "hold must succeed with empty provider output, got $RC"
run release sbx-a
[ "$RC" -eq 0 ] || fail "release must succeed with empty provider output, got $RC"
reset_argv_log
run snapshot sbx-a before-change
[ "$RC" -eq 0 ] || fail "snapshot must succeed with empty provider output, got $RC"
argv_has snapshot
argv_has before-change
run rollback sbx-a before-change
[ "$RC" -eq 0 ] || fail "rollback must succeed with empty provider output, got $RC"
pass "ok - extend, hold, release, snapshot, and rollback validate argv and accept empty output"

POLICY_OUT="name=sbx-a
profile=default
rule=in ssh from 10.0.0.5
rule=out dns any
rule=out https any"
set_fake 0 "" "$POLICY_OUT"
run policy sbx-a
[ "$RC" -eq 0 ] || fail "policy must pass through profile and repeated rules, got $RC"
printf '%s\n' "$POLICY_OUT" | cmp -s - "$OUT" || fail "policy stdout must equal the validated provider record"
set_fake 0 "" "rule=out dns any"
run policy sbx-a
[ "$RC" -eq 3 ] || fail "policy output missing profile must be refused, got $RC"
set_fake 0 "" "profile=default
state=running"
run policy sbx-a
[ "$RC" -eq 3 ] || fail "a state key in policy output must be refused, got $RC"
pass "ok - policy passes through profile and repeated rule lines, refuses off-set keys"

# --- destroy --------------------------------------------------------------------

set_fake 1 "destroy refused: fm_task label 't9' does not match expected 't1'"
run destroy sbx-a --expect-task t1
[ "$RC" -eq 3 ] || fail "a label-mismatch destroy must surface as a refusal (exit 3), got $RC"
grep -q "fm_task label" "$ERR" || fail "the destroy refusal must include the provider's stderr reason"
grep -q "exited 1" "$ERR" || fail "the destroy refusal must name the provider exit status"
reset_argv_log
set_fake 0 "" ""
run destroy sbx-gone --expect-task t1
[ "$RC" -eq 0 ] || fail "destroying an absent sandbox must be success, got $RC"
[ ! -s "$OUT" ] || fail "destroy with empty provider output must print nothing"
argv_has destroy
argv_has sbx-gone
argv_has --expect-task
argv_has t1
argv_has --home
argv_has "$TAG"
pass "ok - destroy surfaces label mismatch as a refusal and treats absent as success"

# --- capacity is distinguishable ---------------------------------------------------

set_fake 75 ""
run create t1
[ "$RC" -eq 4 ] || fail "a provider capacity refusal (exit 75) must surface as exit 4, got $RC"
grep -qi "capacity" "$ERR" || fail "the capacity blocker must say capacity"
set_fake 1 "provider exploded"
run create t1
[ "$RC" -eq 3 ] || fail "a generic provider failure must stay exit 3, got $RC"
[ "$RC" -ne 4 ] || fail "generic failure and capacity must be distinguishable"
pass "ok - a capacity refusal (provider exit 75) is a distinguishable blocker (exit 4)"

# --- argv-only invocation ---------------------------------------------------------

EVIL="a; \$(touch $PWN) | rm -rf /"
reset_argv_log
set_fake 0 "" ""
run exec sbx-a -- printf '%s' "$EVIL"
[ "$RC" -eq 0 ] || fail "exec must succeed against the fake provider, got $RC"
grep -qxF "ARG:$EVIL" "$ARGV_LOG" || fail "exec must pass the command argument as one verbatim argv element"
[ ! -e "$PWN" ] || fail "the exec argument must never be shell-interpolated"
reset_argv_log
run exec sbx-a -- git -C /opt/firstmate fetch --prune
[ "$RC" -eq 0 ] || fail "exec with several arguments must succeed, got $RC"
argv_has git
argv_has -C
argv_has /opt/firstmate
argv_has fetch
argv_has --prune
pass "ok - exec relays argv verbatim with no shell interpolation"

set_fake 42 "" "raw command output
not key=value at all"
run exec sbx-a -- /usr/bin/make check
[ "$RC" -eq 42 ] || fail "exec must relay the provider's exit status verbatim, got $RC"
printf 'raw command output\nnot key=value at all' | cmp -s - "$OUT" || fail "exec must relay stdout verbatim without key=value validation"
pass "ok - exec relays raw stdout and exit status without the key=value contract"

# --- provider availability --------------------------------------------------------

NOEXEC="$TMP_ROOT/noexec-provider.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$NOEXEC"
chmod 644 "$NOEXEC"
printf '%s\n' "$NOEXEC" "default_profile=default" "ttl=4h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run status sbx-a
[ "$RC" -eq 3 ] || fail "a non-executable provider must be refused, got $RC"
printf '%s\n' "$TMP_ROOT/missing-provider.sh" "default_profile=default" "ttl=4h" "ssh_include=/abs" > "$HOME_DIR/config/sandbox-provider"
run status sbx-a
[ "$RC" -eq 3 ] || fail "a missing provider must be refused, got $RC"
pass "ok - a missing or non-executable provider is refused"

printf 'done\n'
