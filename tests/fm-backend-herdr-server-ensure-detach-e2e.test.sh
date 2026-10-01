#!/usr/bin/env bash
# tests/fm-backend-herdr-server-ensure-detach-e2e.test.sh - real-herdr
# regression test for the 2026-10-01 remote-doctor hang (agent01, Ubuntu
# 24.04, herdr 0.9.1): `bin/fm-remote-doctor.sh --fix` never returned on Linux
# after starting the Herdr server, hanging `bin/fm-remote-home-seed.sh`.
#
# Cause (verified against the real herdr 0.9.1 on Linux): bash applies the
# temporary redirections of a redirected function call - the doctor's
# start_herdr_server uses exactly
# `fm_backend_herdr_server_ensure <session> >/dev/null 2>&1` - by saving the
# caller's original stdout/stderr on close-on-exec fds for undo. The async
# fork inside the function inherited those saves and stayed alive as a bash
# wrapper waiting on `herdr server` forever, so the caller's original output
# descriptors never closed and any reader of that output to EOF (the remote
# seeder's command substitution over ssh, or sshd's session teardown) blocked
# forever. The wrapper even kept the doctor's own cmdline, which is why the
# hang surfaced as "the doctor sits in do_wait".
#
# This suite drives the real fm_backend_herdr_server_ensure against its own
# isolated lab session (never the captain's default) inside a command
# substitution whose pipe only closes once every descriptor holder exits,
# exactly like the seeder's capture. It asserts that caller returns promptly
# and that the server is genuinely running afterwards: a "fix" that failed to
# start the server would return instantly too, so the positive check is part
# of the same regression.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-ensure-detach-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-ensure-detach.XXXXXX")
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

# --- the hang shape -----------------------------------------------------------
# Two layers, exactly like the field: a "doctor" script whose only job is the
# redirected ensure call bin/fm-remote-doctor.sh's start_herdr_server makes,
# and a capturing caller that reads the doctor's merged output to EOF the way
# fm-remote-readiness-lib.sh captures the doctor over ssh. The capture job's
# substitution pipe only reaches EOF once every holder of the saved
# descriptors exits, so its result file appearing at all proves the launcher
# kept no descriptor-holding survivor. Bounded by a wall-clock deadline
# instead of `timeout` so the suite stays portable to hosts without
# coreutils' timeout (macOS).
DOCTOR_SHAPE="$SCRATCH/mini-doctor.sh"
cat > "$DOCTOR_SHAPE" <<'MINI'
#!/usr/bin/env bash
set -u
. "${MINI_ROOT:?}/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
. "${MINI_ROOT:?}/bin/fm-backend.sh"
fm_backend_source herdr || exit 9
# start_herdr_server's exact call shape (bin/fm-remote-doctor.sh): the
# redirected ensure call, output discarded, while the caller above captures
# this whole script's output.
fm_backend_herdr_server_ensure "${MINI_SESSION:?}" >/dev/null 2>&1
MINI
chmod +x "$DOCTOR_SHAPE"
export MINI_ROOT="$ROOT" MINI_SESSION="$SESSION"

RESULT="$SCRATCH/capture.result"
( out=$(bash "$DOCTOR_SHAPE" 2>&1); rc=$?; printf '%s %s\n' "$rc" "$out" > "$RESULT" ) &
CAPTURE_PID=$!

deadline=$((SECONDS + 45))
while [ ! -s "$RESULT" ] && [ "$SECONDS" -lt "$deadline" ]; do
  sleep 0.5
done
[ -s "$RESULT" ] || fail "a caller capturing the ensure's doctor-shaped output never returned within 45s (the detached-server descriptor hang)"
[ "$(awk '{print $1}' "$RESULT")" = "0" ] || fail "the doctor-shaped ensure call reported failure: $(cat "$RESULT")"
pass "a caller capturing the ensure's output returned promptly"

running=$(fm_backend_herdr_cli "$SESSION" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
[ "$running" = "true" ] || fail "the isolated session's server did not end up running after the ensure"
pass "the ensure started the isolated session's server"

wait "$CAPTURE_PID" 2>/dev/null || true
