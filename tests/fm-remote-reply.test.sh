#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
printf '# Mentioned but never offered\n' > "$REMOTE/data/reply/prose-only.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
if [ -n "${FM_REMOTE_REPLY_POLL_LOG:-}" ]; then
  printf 'x\n' >> "$FM_REMOTE_REPLY_POLL_LOG"
fi
[ "${FM_REMOTE_REPLY_FAIL_READ:-}" != 1 ] || exit 255
host=$1
entry=$2
shift 2
case "$host" in remote-mac|sbx-task) ;; *) exit 91 ;; esac
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
if [ "${FM_REMOTE_REPLY_FAIL_FILE:-}" = 1 ]; then
  command=$(printf '%s' "$4" | base64 --decode | tr '\0' '\n' | head -n 1)
  [ "$command" != fm-remote-file.sh ] || exit 255
fi
if [ -s "$FM_REPLY_FETCH_MODE" ]; then
  command=$(printf '%s' "$4" | base64 --decode | tr '\0' '\n' | head -n 1)
  if [ "$command" = fm-remote-file.sh ]; then
    case "$(cat "$FM_REPLY_FETCH_MODE")" in
      oversized) head -c 1048577 /dev/zero; exit 0 ;;
      endless) exec yes x ;;
      stderr) head -c 65537 /dev/zero >&2; exit 0 ;;
      stalled) printf partial; exec sleep 60 ;;
      partial) printf partial; exit 1 ;;
    esac
  fi
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_REPLY_FETCH_MODE="$TMP_ROOT/fetch-mode" \
  FM_REMOTE_REPLY_FETCH_SECONDS="${FM_REMOTE_REPLY_FETCH_SECONDS:-}" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS="${FM_REMOTE_REPLY_WAIT_SECONDS:-10}" \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}

stop_reply_listener() {
  local pid _
  pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# Block until this generation's capture has been applied. A live listener keeps
# its claim across polls, so start is only launched when nothing owns the source.
await_reply_result() { # <result-path>
  local result=$1 handled=${1%.result}.handled attempt
  for attempt in $(seq 1 800); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    # A replayed handle replaces the registration. Its old listener can still
    # be live at entry, then exit when it notices that replacement. Supply the
    # next supervision check here too; this fixture has no watcher to do it.
    if [ $((attempt % 20)) -eq 1 ] && [ "$(reply_owner)" != live ]; then
      remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
    fi
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Drive the real delta-reader executable across its unchanged-file wait.
# The recording sleep appends a complete line after the initial empty snapshot,
# so the next snapshot must deliver it without consuming or modifying the log.
delta_cadence_case() {
  local label=$1 override=$2 expected=$3 dir log empty_hash
  dir="$TMP_ROOT/delta-$label"
  mkdir -p "$dir/bin" "$dir/home/state"
  log="$dir/home/state/replies.status"
  : > "$log"
  empty_hash=$(sha256_file "$log")
  cat > "$dir/bin/sleep" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FM_DELTA_SLEEP_LOG"
printf 'cadence-delivered\n' >> "$FM_DELTA_APPEND_LOG"
exec /bin/sleep "$@"
SH
  chmod +x "$dir/bin/sleep"
  FM_HOME="$dir/home" PATH="$dir/bin:$PATH" FM_REMOTE_DELTA_POLL_SECONDS="$override" \
    FM_DELTA_SLEEP_LOG="$dir/sleeps" FM_DELTA_APPEND_LOG="$log" \
    "$BASH" "$ROOT/bin/fm-remote-delta-read.sh" state/replies.status 0 "$empty_hash" 30 \
    > "$dir/result" || fail "$label delta reader failed"
  [ "$(cat "$dir/sleeps")" = "$expected" ] || fail "$label delta reader did not wait $expected seconds"
  assert_grep 'status=delta' "$dir/result" "$label delta reader did not publish a delta"
  assert_grep 'cadence-delivered' "$dir/result" "$label delta reader lost the appended complete line"
  [ "$(cat "$log")" = cadence-delivered ] || fail "$label delta reader changed its source log"
  pass "$label delta reader waits $expected seconds then delivers a non-destructive complete-line delta"
}
delta_cadence_case default '' 0.5
delta_cadence_case override 0.07 0.07

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef] [at=1700000000]: build verified report=data/reply/report.md\n' \
  >> "$REMOTE/state/parent-replies.status"
RESULT=
for _ in $(seq 1 800); do
  RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null || true)
  [ -n "$RESULT" ] && [ -f "${RESULT%.result}.handled" ] && break
  sleep 0.05
done
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null || true)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
# One remote note, one announcement: the adapter declares self-announcing, so a
# fully autohandled capture publishes NO check wake - the mirrored status bytes
# are the single announcement, observed here through the same signature-vs-seen
# gate the watcher's signal scan and the drain's annotation check consume.
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an autohandled remote-reply capture still published a duplicate check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" && fail "the mirrored reply bytes are not visible to the watcher signal scan"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

# The runner applies a captured result through this adapter itself, so the reply
# is already mirrored, acknowledged, and the next source re-armed before any
# handler runs. That is the primary guarantee; assert it before exercising the
# handler's own path below.
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
pass "a captured delta is applied, acknowledged, and re-armed without a handler"

# Now the handler's own retry path, from the state a crash between applying and
# acknowledging leaves behind: the acknowledgement is gone and re-arming fails.
rm -f "$PARENT/state/procevent-inbox/$SID.1.handled"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=0' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not replay the committed reply"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
assert_grep 'done [corr=0123456789abcdef] [at=1700000000]: build verified' "$PARENT/state/ios.status" \
  "relay replaced the source event time with observation time"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.2.result" \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
# The runner already applied and acknowledged this capture. Drop that genuine
# acknowledgement and put an unsafe one in its place, so the handler's refusal
# to trust a non-regular marker stays under test.
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.3.result" \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
grep -Fxq 'working [corr=1111111111111111]: second generation' "$PARENT/state/ios.status" \
  || fail "relay invented an emission time for a legacy source event"
pass "later generations cannot invalidate an unacknowledged ingested result"

# The channel mirrors the remote mate's content-bearing status lines at most once
# while omitting blank separators. A remote mate's own progress line and a NEWLY
# raised needs-decision carry no corr= by charter contract, and a delta carrying
# them alongside a correlated answer must ingest whole: every content-bearing
# line reaches the parent stream, the new decision reaches the parent's
# open-decision fold, the correlated line still settles its pending-reply record,
# and the cursor advances so the channel cannot wedge on a line it once refused.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{
  printf 'working [key=version-audit]: family --version audit complete (data/reply/prose-only.md)\n'
  printf 'needs-decision [key=rough-cut-version]: implement --version or retire the tool\n'
  printf 'needs-decision [at=1700000000]: which base branch?\n'
  printf 'needs-decision [at=1700086400]: which base branch?\n'
  printf 'done [corr=%s]: release chain audited\n' "$PENDING_CORR"
} >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.4.result" \
  || fail "the mirrored status stream was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.4.result"
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" > "$TMP_ROOT/handle-mirror.out" 2>&1 \
  || fail "an uncorrelated status line stopped the delta: $(cat "$TMP_ROOT/handle-mirror.out")"
assert_grep 'working [key=version-audit]' "$PARENT/state/ios.status" "an uncorrelated progress line never reached the parent stream"
assert_grep 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status" "a newly raised remote decision never reached the parent stream"
assert_grep "done [corr=$PENDING_CORR]" "$PARENT/state/ios.status" "the correlated answer sharing the delta was lost"
for epoch in 1700000000 1700086400; do
  grep -Fxq "needs-decision [at=$epoch]: which base branch?" "$PARENT/state/ios.status" \
    || fail "relay discarded a distinct event with identical text and a different time"
done
mirror_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past an uncorrelated line"
# The prose line NAMES a path that really does exist on the remote, so only the
# structured-pointer trigger can explain the parent never fetching it.
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/prose-only.md" \
  "a bare path mentioned in prose was fetched as though the line offered it"
assert_grep 'audit complete (data/reply/prose-only.md)' "$PARENT/state/ios.status" \
  "the prose mention was rewritten as though its document had been fetched"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "a bare path mentioned in prose raised a document transfer obligation"
pass "the remote status and decision model mirrors and the cursor advances"

# The newly raised decision must be indistinguishable from a local mate's, so the
# shared fold - not this adapter - decides it is open.
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
OPEN=$(status_open_decisions "$PARENT/state/ios.status")
printf '%s' "$OPEN" | grep -q '^rough-cut-version	needs-decision	' \
  || fail "the remote mate's new decision did not surface as open to the parent: $OPEN"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$PENDING_CORR" phase)" = resolved ] \
  || fail "the correlated answer in the same delta did not settle its pending-reply record"
pass "a remote mate's new decision folds open exactly as a local mate's does"

# Ingesting the same generation again is idempotent: no duplicated lines and no
# cursor movement, so a replay can never wedge or double-count the stream.
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replaying the mirrored delta duplicated the new decision"
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "replaying the mirrored delta moved the cursor"
pass "a replayed mirrored delta is idempotent in both the stream and the cursor"
[ "$(grep -Fc ': which base branch?' "$PARENT/state/ios.status")" -eq 2 ] \
  || fail "replaying a delta duplicated distinct timed requests"
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf 'Remote source status records:\n'
  cat "$REMOTE/state/parent-replies.status"
  printf '\nParent status after handling and replaying generation 4:\n'
  cat "$PARENT/state/ios.status"
  printf '\nCommitted remote cursor:\n'
  cat "$PARENT/state/remote-replies/ios.cursor"
fi

# Bytes crossing a machine boundary are normalized, never dropped: a control
# character cannot make the parent's status file unsafe and cannot stop the
# stream either.
printf 'blocked [key=ctl]: escape \033[31mhere\033[0m bell \007 caf\xc3\xa9 end\n' \
  >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.5.result" \
  || fail "the control-character line was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.5.result"
remote_env "$ADAPTER" handle ios 5 "$RESULT_FIVE" >/dev/null 2>&1 \
  || fail "a control character stopped the stream"
assert_grep 'blocked [key=ctl]: escape ?[31mhere' "$PARENT/state/ios.status" \
  "the control-character line was not mirrored in normalized form"
[ -z "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$PARENT/state/ios.status")" ] \
  || fail "a control byte reached the parent status file"
assert_grep "$(printf 'caf\xc3\xa9 end')" "$PARENT/state/ios.status" \
  "normalization mangled a UTF-8 note a local secondmate could have written"
ctl_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$ctl_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a control-character line"
pass "transported control bytes are normalized in place and never stop the stream"

printf 'status=delta\n' >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.6.result" \
  || fail "the header-collision line was not captured"
RESULT_SIX="$PARENT/state/procevent-inbox/$SID.6.result"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 \
  || fail "a payload protocol-field name stopped the stream"
assert_grep 'status=delta' "$PARENT/state/ios.status" \
  "the payload protocol-field line did not reach the parent stream"
collision_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$collision_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a payload protocol-field line"
pass "payload protocol-field names cannot collide with transport metadata"

printf 'working [key=nul-byte]: before\000after\n' >> "$REMOTE/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.7.result" \
  || fail "the NUL-bearing line was not captured"
RESULT_SEVEN="$PARENT/state/procevent-inbox/$SID.7.result"
remote_env "$ADAPTER" handle ios 7 "$RESULT_SEVEN" >/dev/null 2>&1 \
  || fail "a NUL byte stopped the stream"
assert_grep 'working [key=nul-byte]: before?after' "$PARENT/state/ios.status" \
  "the NUL byte was not normalized in place"
nul_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$nul_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a NUL-bearing line"
pass "NUL bytes are normalized in place before shell line processing"

stop_reply_listener || fail "the reply listener did not stop before the obstructed document capture"
printf '# Retryable remote answer\n' > "$REMOTE/data/reply/retry.md"
printf 'done [key=retry-document]: retry local storage report=data/reply/retry.md\n' \
  >> "$REMOTE/state/parent-replies.status"
# Obstruct local document storage BEFORE the capture, so the runner's own
# automatic application fails for real. That is the documented fallback: a
# capture whose application does not complete stays unacknowledged and
# uncommitted, and the handler finishes it once storage recovers.
retry_destination="$PARENT/data/remote-secondmates/ios/data/reply/retry.md"
retry_decoy="$TMP_ROOT/retry-decoy.md"
printf 'local decoy\n' > "$retry_decoy"
ln -s "$retry_decoy" "$retry_destination"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the retryable document line was not captured"
RESULT_EIGHT="$PARENT/state/procevent-inbox/$SID.8.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.handled" \
  "a capture whose automatic application failed was acknowledged anyway"
# The self-announcing declaration never silences a capture the adapter could
# NOT fully apply: this one must still publish its check wake for the handler.
assert_grep "procevent remote-reply $SID 8" "$PARENT/state/.wake-queue" \
  "a not-fully-applied capture lost its check-wake announcement"
assert_no_grep 'retry local storage' "$PARENT/state/.wake-queue" \
  "reply payload leaked into the event queue"
retry_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
set +e
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" > "$TMP_ROOT/handle-local-document-failure.out" 2>&1
local_document_rc=$?
set -e
[ "$local_document_rc" -ne 0 ] || fail "local document storage failure committed the delta"
assert_grep 'could not store referenced remote document' "$TMP_ROOT/handle-local-document-failure.out" \
  "local document storage failure was misclassified as remote refusal"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$retry_cursor_before" ] \
  || fail "local document storage failure advanced the cursor"
assert_no_grep 'done [key=retry-document]' "$PARENT/state/ios.status" \
  "local document storage failure mirrored an undelivered line"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "local document storage failure raised a permanent remote refusal"
rm -f "$retry_destination"
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" >/dev/null \
  || fail "the document delta did not succeed after local storage recovered"
assert_grep 'data/remote-secondmates/ios/data/reply/retry.md' "$PARENT/state/ios.status" \
  "the retried document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/retry.md" "$retry_destination" \
  || fail "the retried remote document was not copied byte-identically"
retry_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$retry_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recovered document delta did not advance the cursor"
pass "local document storage failures remain retryable until delivery succeeds"

# ---------------------------------------------------------------------------
# A document a line OFFERS is fetched; one the reader cannot deliver fails open.
# The reader cannot tell a report still being written from one that will never
# exist, so a refusal never becomes a decision on the parent's board: the line
# keeps its own pointer, the cursor advances, and an unkeyed note says why.
GEN=8
mirror_lines() { # <line>...
  GEN=$((GEN + 1))
  printf '%s\n' "$@" >> "$REMOTE/state/parent-replies.status"
  await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
    || fail "generation $GEN was not captured"
  assert_present "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
    "generation $GEN was captured but never applied"
}
mirrored_cursor_is_current() { # <label>
  local offset
  offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
  assert_grep "offset=$offset" "$PARENT/state/remote-replies/ios.cursor" "$1"
}
assert_no_document_decision() { # <label>
  if status_open_decisions "$PARENT/state/ios.status" | grep -q '^remote-reply-document-'; then
    fail "$1"
  fi
  assert_no_grep '[key=remote-reply-document-' "$PARENT/state/ios.status" "$1"
}

printf '# valid report behind a malformed pointer\n' > "$REMOTE/data/reply/result.md"
mirror_lines 'working [key=malformed-report]: malformed offer report=data/reply/result.md.bak'
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/result.md" \
  "a valid prefix of a malformed report pointer was fetched"
assert_grep 'report=data/reply/result.md.bak' "$PARENT/state/ios.status" \
  "a valid prefix of a malformed report pointer was rewritten"
assert_no_document_decision "a malformed report pointer raised a document decision"
mirrored_cursor_is_current "a malformed report pointer prevented the cursor from advancing"
pass "a structured pointer must end at its token boundary"

printf '# first adjacent report\n' > "$REMOTE/data/reply/adjacent-a.md"
printf '# second adjacent report\n' > "$REMOTE/data/reply/adjacent-b.md"
mirror_lines 'done [key=adjacent-reports]: report=data/reply/adjacent-a.md,report=data/reply/adjacent-b.md report=data/reply/result.md alongside report=data/reply/result.md.bak'
cmp -s "$REMOTE/data/reply/adjacent-a.md" "$PARENT/data/remote-secondmates/ios/data/reply/adjacent-a.md" \
  || fail "the first comma-separated structured pointer was not fetched"
cmp -s "$REMOTE/data/reply/adjacent-b.md" "$PARENT/data/remote-secondmates/ios/data/reply/adjacent-b.md" \
  || fail "the second comma-separated structured pointer was not fetched"
cmp -s "$REMOTE/data/reply/result.md" "$PARENT/data/remote-secondmates/ios/data/reply/result.md" \
  || fail "the whitespace-separated structured pointer was not fetched"
assert_grep 'report=data/remote-secondmates/ios/data/reply/adjacent-a.md,report=data/remote-secondmates/ios/data/reply/adjacent-b.md report=data/remote-secondmates/ios/data/reply/result.md alongside report=data/reply/result.md.bak' "$PARENT/state/ios.status" \
  "structured pointer rewriting skipped an adjacent pointer or changed a malformed token"
mirrored_cursor_is_current "adjacent structured pointers prevented the cursor from advancing"
pass "adjacent pointers are fetched while malformed tokens remain unchanged"

# A rejected candidate must not make the text right after it look like the start
# of a line: the second `report=` here has no boundary of its own.
printf '# glued report\n' > "$REMOTE/data/reply/glued.md"
mirror_lines 'working [key=glued-pointers]: glued report=data/reply/glued-prefix.mdreport=data/reply/glued.md'
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/glued.md" \
  "a pointer with no preceding boundary was fetched after a rejected candidate"
assert_grep 'glued report=data/reply/glued-prefix.mdreport=data/reply/glued.md' "$PARENT/state/ios.status" \
  "a pointer with no preceding boundary was rewritten after a rejected candidate"
pass "a rejected candidate never gives the following text a false leading boundary"

# A `report=` under a remote-secondmates mirror tree is fetched like any other
# structured offer. When this mate genuinely holds it, it is a nested remote
# report worth relaying; when it does not, the fetch fails open and harmlessly.
mkdir -p "$REMOTE/data/remote-secondmates/nested/data/reply"
printf '# nested grandchild report\n' > "$REMOTE/data/remote-secondmates/nested/data/reply/report.md"
mirror_lines 'done [key=nested-remote]: nested report=data/remote-secondmates/nested/data/reply/report.md foreign report=data/remote-secondmates/other/data/reply/report.md'
cmp -s "$REMOTE/data/remote-secondmates/nested/data/reply/report.md" \
  "$PARENT/data/remote-secondmates/ios/data/remote-secondmates/nested/data/reply/report.md" \
  || fail "a nested remote report this mate holds was not relayed"
assert_grep 'nested report=data/remote-secondmates/ios/data/remote-secondmates/nested/data/reply/report.md foreign report=data/remote-secondmates/other/data/reply/report.md' "$PARENT/state/ios.status" \
  "the nested pointer was not rewritten or the undeliverable foreign pointer was changed"
assert_grep 'note: remote document did not transfer for ios: data/remote-secondmates/other/data/reply/report.md - ' <(sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/ios.status") \
  "an undeliverable foreign pointer left no note"
assert_no_document_decision "an undeliverable foreign pointer raised a document decision"
mirrored_cursor_is_current "an undeliverable foreign pointer prevented the cursor from advancing"
pass "nested remote reports relay while an undeliverable foreign pointer fails open"

# The reported incident, end to end. The mate announces a scout and names in
# prose the path its report WILL be written to, then explains the resulting
# false alarm in two more lines of the same delta. None of that is an offer, so
# nothing is fetched, nothing is noted, and no decision ever opens. The report
# arrives through the ledger publisher's structured offer once it exists.
INCIDENT_DOC=data/reply/voice-scout-report.md
rm -f "$REMOTE/$INCIDENT_DOC"
mirror_lines "reply [corr=3333333333333333]: dispatched the voice scout, report path $INCIDENT_DOC, will relay on completion"
mirror_lines \
  "reply [corr=3333333333333333]: No report to transfer YET - $INCIDENT_DOC is NOT yet written; nothing is lost" \
  "reply [corr=3333333333333333]: same - the report does not exist yet (scout still working, $INCIDENT_DOC not written)"
assert_no_document_decision "a report path mentioned in prose raised a document decision"
assert_no_grep "note: remote document did not transfer for ios: $INCIDENT_DOC" "$PARENT/state/ios.status" \
  "a report path mentioned in prose was treated as an undeliverable offer"
assert_grep "report path $INCIDENT_DOC, will relay" "$PARENT/state/ios.status" \
  "the prose announcement was not mirrored verbatim"
mirrored_cursor_is_current "the prose announcement delta did not advance the cursor"
printf '# voice scout report\n\nfindings\n' > "$REMOTE/$INCIDENT_DOC"
# The exact shape bin/fm-inactive-reconcile.sh publishes for a finished child.
mirror_lines "done [key=child-outcome-voice-scout-done-ab12cd34]: child voice-scout done: report ready mode=scout report=$INCIDENT_DOC"
cmp -s "$REMOTE/$INCIDENT_DOC" "$PARENT/data/remote-secondmates/ios/$INCIDENT_DOC" \
  || fail "the structured ledger offer did not deliver the finished report"
assert_grep "report ready mode=scout report=data/remote-secondmates/ios/$INCIDENT_DOC" "$PARENT/state/ios.status" \
  "the structured ledger offer was not rewritten to its local copy"
assert_no_document_decision "the reported incident left a document decision standing"
pass "the reported incident raises no standing decision and still delivers the report"

# A structured offer the reader cannot deliver fails open with its own reason.
# Offered again twice in one delta, the unchanged note is not repeated.
mirror_lines 'reply [corr=4444444444444444]: dispatched a scout report=data/reply/never-written.md'
assert_grep 'note: remote document did not transfer for ios: data/reply/never-written.md - file is not a non-symlink regular file' <(sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/ios.status") \
  "an undeliverable structured offer left no note carrying the reader's reason"
status_line_at_epoch "$(grep -E '^note( \[at=[0-9]+\])?: remote document did not transfer for ios: data/reply/never-written\.md' "$PARENT/state/ios.status")" >/dev/null \
  || fail "new remote document note has unknown emission time"
assert_grep 'dispatched a scout report=data/reply/never-written.md' "$PARENT/state/ios.status" \
  "an undeliverable offer's line was not mirrored with its own pointer intact"
assert_no_document_decision "an undeliverable structured offer raised a document decision"
mirrored_cursor_is_current "an undeliverable structured offer held the cursor back"
mirror_lines \
  'reply [corr=4444444444444444]: still writing report=data/reply/never-written.md' \
  'reply [corr=4444444444444444]: same, report=data/reply/never-written.md'
[ "$(sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/ios.status" | grep -cF 'note: remote document did not transfer for ios: data/reply/never-written.md')" -eq 1 ] \
  || fail "re-offering the same undeliverable document repeated its note"
assert_no_document_decision "re-offering an undeliverable document raised a document decision"
pass "an undeliverable structured offer fails open with one note and never a decision"

# The positive remote-refusal case with a genuinely non-transient cause: the
# reader bounds document size, and that refusal is visible by its own reason.
head -c 300000 /dev/zero | tr '\0' 'x' > "$REMOTE/data/reply/big.md"
mirror_lines 'done [key=big-report]: oversize deliverable report=data/reply/big.md'
assert_grep 'note: remote document did not transfer for ios: data/reply/big.md - file exceeds max-bytes' <(sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/ios.status") \
  "an oversize document's refusal did not surface with its reason"
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/big.md" \
  "a refused oversize document was stored locally anyway"
assert_no_document_decision "an oversize document raised a document decision"
mirrored_cursor_is_current "an oversize document held the cursor back"
pass "a remote refusal surfaces its own reason without opening a decision"

# A failed extraction pass must leave the delta wholly uncommitted. Once the
# parser works again, the same captured delta applies in full.
printf '# extraction-failure probe\n' > "$REMOTE/data/reply/extractfail.md"
GEN=$((GEN + 1))
stop_reply_listener || fail "the reply listener did not stop before the extraction-failure capture"
printf 'done [key=extraction-failure]: probe report=data/reply/extractfail.md\n' \
  >> "$REMOTE/state/parent-replies.status"
extractfail_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-extractfail"
EXTRACT_FAIL_BIN="$TMP_ROOT/extract-fail-bin"
mkdir -p "$EXTRACT_FAIL_BIN"
REAL_AWK=$(command -v awk)
# The stand-in awk refuses only the extraction pass, so every other awk the
# relay depends on keeps working.
{
  cat <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  [ "$argument" != mode=extract ] || exit 97
done
SH
  printf 'exec %q "$@"\n' "$REAL_AWK"
} > "$EXTRACT_FAIL_BIN/awk"
chmod +x "$EXTRACT_FAIL_BIN/awk"
PATH="$EXTRACT_FAIL_BIN:$PATH" remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" \
  >/dev/null 2>&1 || true
RESULT_EXTRACTFAIL="$PARENT/state/procevent-inbox/$SID.$GEN.result"
assert_present "$RESULT_EXTRACTFAIL" "the extraction-failure delta was not captured"
assert_absent "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "a capture whose pointer extraction failed was acknowledged anyway"
extractfail_rc=0
PATH="$EXTRACT_FAIL_BIN:$PATH" remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_EXTRACTFAIL" \
  > "$TMP_ROOT/extract-fail.out" 2>&1 || extractfail_rc=$?
[ "$extractfail_rc" -ne 0 ] || fail "the failed extraction pass reported success"
assert_grep 'cannot extract remote document pointers' "$TMP_ROOT/extract-fail.out" \
  "the failed extraction pass did not report its failure"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$extractfail_cursor_before" ] \
  || fail "a failed extraction pass advanced the cursor past dropped status content"
cmp -s "$TMP_ROOT/ios-status-before-extractfail" "$PARENT/state/ios.status" \
  || fail "a failed extraction pass appended partial or blank status content"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_EXTRACTFAIL" >/dev/null \
  || fail "the delta did not apply once pointer extraction worked again"
assert_grep 'report=data/remote-secondmates/ios/data/reply/extractfail.md' "$PARENT/state/ios.status" \
  "the recovered delta did not mirror its rewritten pointer"
cmp -s "$REMOTE/data/reply/extractfail.md" "$PARENT/data/remote-secondmates/ios/data/reply/extractfail.md" \
  || fail "the recovered delta did not fetch its offered document"
mirrored_cursor_is_current "the recovered extraction-failure delta did not advance the cursor"
pass "a failed pointer extraction never commits a partial delta"

# A mirror write that cannot complete must fail loudly rather than leave blank
# or partial content behind and advance the cursor past status bytes nobody
# ever received. The delta stays uncommitted and applies in full once the
# stream is writable again.
printf '# write-failure probe\n' > "$REMOTE/data/reply/writefail.md"
GEN=$((GEN + 1))
stop_reply_listener || fail "the reply listener did not stop before the unwritable-stream capture"
printf 'done [key=write-failure]: probe report=data/reply/writefail.md\n' \
  >> "$REMOTE/state/parent-replies.status"
writefail_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-writefail"
chmod 444 "$PARENT/state/ios.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 || true
RESULT_WRITEFAIL="$PARENT/state/procevent-inbox/$SID.$GEN.result"
assert_present "$RESULT_WRITEFAIL" "the unwritable-stream delta was not captured"
assert_absent "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "a capture whose mirror write failed was acknowledged anyway"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$writefail_cursor_before" ] \
  || fail "a failed mirror write advanced the cursor past dropped status content"
chmod 644 "$PARENT/state/ios.status"
cmp -s "$TMP_ROOT/ios-status-before-writefail" "$PARENT/state/ios.status" \
  || fail "a failed mirror write left partial or blank content on the parent stream"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_WRITEFAIL" >/dev/null \
  || fail "the delta did not apply once the parent stream was writable again"
assert_grep 'report=data/remote-secondmates/ios/data/reply/writefail.md' "$PARENT/state/ios.status" \
  "the recovered delta did not mirror its rewritten pointer"
mirrored_cursor_is_current "the recovered delta did not advance the cursor"
pass "a failed mirror write never drops status content or advances the cursor"

# A source line remains the replay identity even when document availability
# changes between a successful mirror append and a failed ingestion commit.
REPLAY_LINE='needs-decision [key=replay-decision]: pick report=data/reply/replay.md'
rm -f "$REMOTE/data/reply/replay.md"
GEN=$((GEN + 1))
stop_reply_listener || fail "the reply listener did not stop before the receipt-failure capture"
printf '%s\n' "$REPLAY_LINE" >> "$REMOTE/state/parent-replies.status"
replay_commit_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
RECEIPT_FAIL_BIN="$TMP_ROOT/receipt-fail-bin"
mkdir -p "$RECEIPT_FAIL_BIN"
REAL_MKTEMP=$(command -v mktemp)
{
  cat <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */state/remote-replies/.ingested.XXXXXX) exit 73 ;;
esac
SH
  printf 'exec %q "$@"\n' "$REAL_MKTEMP"
} > "$RECEIPT_FAIL_BIN/mktemp"
chmod +x "$RECEIPT_FAIL_BIN/mktemp"
PATH="$RECEIPT_FAIL_BIN:$PATH" remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" \
  >/dev/null 2>&1 || true
RESULT_REPLAY_COMMIT="$PARENT/state/procevent-inbox/$SID.$GEN.result"
assert_present "$RESULT_REPLAY_COMMIT" "the replay-identity delta was not captured"
assert_absent "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "the generation whose ingestion receipt failed was acknowledged"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$replay_commit_cursor_before" ] \
  || fail "an ingestion receipt failure advanced the remote reply cursor"
[ "$(grep -cF "$REPLAY_LINE" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "the pre-rewrite decision line was not mirrored exactly once before commit failure"
printf '# replay decision report\n' > "$REMOTE/data/reply/replay.md"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_REPLAY_COMMIT" >/dev/null \
  || fail "the uncommitted generation did not retry after its document arrived"
[ "$(grep -cF "$REPLAY_LINE" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "retrying after document arrival duplicated the source decision line"
assert_no_grep 'needs-decision [key=replay-decision]: pick report=data/remote-secondmates/ios/data/reply/replay.md' \
  "$PARENT/state/ios.status" "retrying after document arrival appended a rewritten duplicate"
assert_present "$PARENT/data/remote-secondmates/ios/data/reply/replay.md" \
  "the retry did not fetch the document that had since arrived"
printf 'resolved [key=replay-decision]: selection complete\n' >> "$PARENT/state/ios.status"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" $'replay-decision\t' \
  "the replay decision fixture did not close before cursor-loss recapture"
stop_reply_listener || fail "the reply listener did not stop before the cursor-loss recapture"
rm -f "$PARENT/state/remote-replies/ios.cursor"
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the replay-identity whole-log recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "the replay-identity whole-log recapture was not applied"
[ "$(grep -cF "$REPLAY_LINE" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "cursor-loss recapture duplicated the resolved decision"
assert_no_grep 'needs-decision [key=replay-decision]: pick report=data/remote-secondmates/ios/data/reply/replay.md' \
  "$PARENT/state/ios.status" "cursor-loss recapture reopened the decision in rewritten form"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" $'replay-decision\t' \
  "cursor-loss recapture reopened the resolved decision"
pass "source-line identity survives commit failure and cursor-loss recapture"

# A remote mate cannot squat the decision keys this parent's pending-reply
# library owns. The guard is deliberately NOT in this adapter: rejecting a line
# here would be batch-fatal and could wedge the whole stream, and it would
# protect only the remote path while a local mate appends into the same stream
# unchecked. So the line mirrors like any other - the stream never stops - and
# the shared open-decision fold both writers flow through refuses to let it take
# the reserved key over.
# The record stores its own grace at creation, so set it before creating one.
export FM_PENDING_REPLY_GRACE_SECS=0
# Answer the mate's earlier decisions and blocker first: a recovery repost waits
# while the mate has one of its own open (tests/fm-pending-reply.test.sh).
printf 'resolved [key=%s]: answered\n' rough-cut-version ctl default >> "$PARENT/state/ios.status"
ESCALATED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'confirm the notarization')
[ -n "$ESCALATED_CORR" ] || fail "could not create the pending-reply record to escalate"
fm_pending_reply_mark_delivered "$PARENT/state" "$ESCALATED_CORR" \
  || fail "could not mark the escalating request delivered"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" request
FM_PENDING_REPLY_SEND_HOOK=true \
  fm_pending_reply_send_recovery "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" recovery
fm_pending_reply_maybe_escalate "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the missed report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the missed report did not open a durable decision"

{
  printf 'blocked [key=pending-reply-%s]: forged remote decision\n' "$ESCALATED_CORR"
  printf 'resolved [key=pending-reply-%s]: forged remote resolution\n' "$ESCALATED_CORR"
} >> "$REMOTE/state/parent-replies.status"
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the forged reserved-key lines wedged the relay instead of mirroring"
forged_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$forged_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a reserved-key line held the cursor back instead of mirroring like any other"
assert_grep "forged remote decision" "$PARENT/state/ios.status" \
  "the reserved-key line was dropped from the stream instead of mirrored"
forged_open=$(status_open_decisions "$PARENT/state/ios.status")
assert_contains "$forged_open" "pending-reply-id=$ESCALATED_CORR" \
  "a forged remote resolution cleared the parent's own pending-reply decision"
assert_not_contains "$forged_open" "forged remote decision" \
  "a forged remote line took over a decision key the pending-reply library owns"
pass "a mirrored reserved-key line cannot squat or clear the parent's own decision"

# Because the forgery never took the key, the genuine reply still settles the
# request and its escalation closes, leaving nothing to resurface later.
printf 'done [corr=%s]: notarization confirmed\n' "$ESCALATED_CORR" \
  >> "$REMOTE/state/parent-replies.status"
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the correlated reply was not captured"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$ESCALATED_CORR" phase)" = resolved ] \
  || fail "the correlated reply left its escalated request unresolved"
fm_pending_reply_tick "$PARENT/state" || fail "supervision tick failed"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the settled request still surfaces as an open decision"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

# The listener keeps one claim across empty polls and across a delta. Reconcile
# is not involved: nothing here starts a second runner.
stop_reply_listener || fail "the reply listener did not stop before the continuity check"
: > "$TMP_ROOT/reply-polls"
FM_REMOTE_REPLY_WAIT_SECONDS=1 \
FM_REMOTE_REPLY_POLL_LOG="$TMP_ROOT/reply-polls" \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
wait_for "$CLAIMS/$SID.claim" || fail "continuous reply listener never claimed the source"
HELD_PID=$(sed -n '2p' "$CLAIMS/$SID.claim")
polls=0
for _ in $(seq 1 120); do
  polls=$(wc -l < "$TMP_ROOT/reply-polls" | tr -d ' ')
  [ "$polls" -ge 2 ] && break
  sleep 0.25
done
[ "$polls" -ge 2 ] || fail "the reply listener did not poll twice while still owned"
[ "$(reply_owner)" = live ] || fail "the reply listener dropped its claim between empty waits"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] \
  || fail "an empty wait replaced the reply listener"
printf 'working [corr=abcdefabcdefabcd]: held across an empty wait\n' \
  >> "$REMOTE/state/parent-replies.status"
for _ in $(seq 1 80); do
  grep -q 'held across an empty wait' "$PARENT/state/ios.status" && break
  sleep 0.1
done
grep -q 'held across an empty wait' "$PARENT/state/ios.status" \
  || fail "a delta appended while the listener was owned was not mirrored"
GEN=$((GEN + 1))
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] \
  || fail "a delta replaced the reply listener"
polls_after_delta=$(wc -l < "$TMP_ROOT/reply-polls" | tr -d ' ')
for _ in $(seq 1 120); do
  polls=$(wc -l < "$TMP_ROOT/reply-polls" | tr -d ' ')
  [ "$polls" -gt "$polls_after_delta" ] && break
  sleep 0.25
done
[ "$polls" -gt "$polls_after_delta" ] || fail "the reply listener did not poll again after a delta"
[ "$(reply_owner)" = live ] || fail "the reply listener dropped its claim after a delta"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] \
  || fail "the post-delta poll was a new listener"
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf 'Continuous listener: owner=%s pid=%s polls=%s; mirrored status: ' \
    "$(reply_owner)" "$HELD_PID" "$polls"
  grep -F 'held across an empty wait' "$PARENT/state/ios.status" | tail -1
fi
stop_reply_listener || fail "the continuity listener did not stop"
pass "a remote reply listener stays owned across empty waits and a delta"

# A failed transport is not an empty wait: do not launch a second read under
# the same owner, even when the launch floor is short.
: > "$TMP_ROOT/failed-polls"
FM_REMOTE_REPLY_FAIL_READ=1 FM_REMOTE_REPLY_POLL_LOG="$TMP_ROOT/failed-polls" \
  FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
failed_reader=$!
wait "$failed_reader" || fail "failed reader did not leave the runner"
sleep 2
[ "$(wc -l < "$TMP_ROOT/failed-polls" | tr -d ' ')" -eq 1 ] \
  || fail "failed reader relaunched within the launch floor"
pass "a failed remote read exits instead of relistening"

# Make local ingestion persistently fail after the delta has been captured.
# Its durable generation must remain the only copy until reconciliation.
mv "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-failure"
mkdir "$PARENT/state/ios.status"
printf 'working: cannot ingest yet\n' >> "$REMOTE/state/parent-replies.status"
failed_gen=$((GEN + 1))
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_REMOTE_REPLY_WAIT_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
failed_ingest=$!
wait "$failed_ingest" || fail "failed ingestion did not leave the runner"
sleep 2
[ -f "$PARENT/state/procevent-inbox/$SID.$failed_gen.result" ] \
  || fail "failed ingestion lost its durable capture"
[ ! -e "$PARENT/state/procevent-inbox/$SID.$((failed_gen + 1)).result" ] \
  || fail "failed ingestion recaptured the same delta"
rmdir "$PARENT/state/ios.status"
mv "$TMP_ROOT/ios-status-before-failure" "$PARENT/state/ios.status"
# The next sections assume the cursor has advanced; apply the one saved result.
remote_env "$ADAPTER" handle ios "$failed_gen" \
  "$PARENT/state/procevent-inbox/$SID.$failed_gen.result" >/dev/null \
  || fail "saved capture could not be retried"
GEN=$failed_gen
pass "persistent ingestion failure leaves exactly one durable capture"

rm -f -- "$PARENT/state/remote-replies/ios.caught-up"
remote_env "$ADAPTER" source ios > "$TMP_ROOT/preempted-source.out" 2>&1 &
PREEMPTED_SOURCE=$!
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the reply poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
set +e
wait "$PREEMPTED_SOURCE"
preempted_rc=$?
set -e
[ "$preempted_rc" -eq 75 ] \
  || fail "a preempted reply poll did not report a closed window: $preempted_rc"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "a preempted reply poll published a caught-up watermark"
pass "a preempted reply poll reports a closed window without publishing channel freshness"

# The per-cycle liveness probe is a non-preemptible job for the same remote home,
# so the job worker preempts the listener's long-poll on every watcher cycle.
# That must not cost the listener: it keeps its claim and polls again, and the
# watcher's reconcile has nothing to relaunch.
: > "$TMP_ROOT/preempted-polls"
FM_REMOTE_REPLY_POLL_LOG="$TMP_ROOT/preempted-polls" FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
PREEMPTED_RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "the preempted-listener case never claimed the source"
HELD_PID=$(sed -n '2p' "$CLAIMS/$SID.claim")
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the listener's poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
polls=0
for _ in $(seq 1 120); do
  polls=$(wc -l < "$TMP_ROOT/preempted-polls" | tr -d ' ')
  [ "$polls" -ge 2 ] && break
  sleep 0.25
done
[ "$polls" -ge 2 ] || fail "the preempted listener did not poll again"
case "$(ps -p "$PREEMPTED_RUNNER" -o stat= 2>/dev/null)" in
  ''|Z*) fail "a preempted poll ended the reply listener" ;;
esac
[ "$(reply_owner)" = live ] || fail "a preempted poll released the listener's claim"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] \
  || fail "a preempted poll replaced the reply listener"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'started=0' \
  "reconcile relaunched a listener after a preempted poll"
[ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$HELD_PID" ] \
  || fail "reconcile replaced the preempted listener"
stop_reply_listener || fail "the preempted listener did not stop"
wait "$PREEMPTED_RUNNER" 2>/dev/null || true
pass "a preempted reply poll keeps its listener and reconcile launches nothing"

# A quiet window is the one moment this channel can prove it is NOT behind, and
# the parent's pending-reply guard needs that proof: a remote report that exists
# but has not been mirrored yet must never be mistaken for a report the mate
# never wrote. The window opened with the log matching the committed cursor, so
# the published watermark is the window's start.
watermark_before=$(date +%s)
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
quiet_rc=$?
set -e
[ "$quiet_rc" -eq 75 ] || fail "a quiet reply window exited with an unexpected status: $quiet_rc"
watermark_after=$(date +%s)
caught_up=$(FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_remote_channel_epoch "$2/state" ios
' _ "$ROOT" "$PARENT")
[ -n "$caught_up" ] || fail "a quiet reply window published no caught-up watermark"
[ "$caught_up" -ge "$watermark_before" ] && [ "$caught_up" -le "$watermark_after" ] \
  || fail "the caught-up watermark ($caught_up) is outside the quiet window"
pass "a quiet reply window publishes the caught-up watermark the reply guard reads"

# The observed already-handled replay class: a lost cursor (an update or
# convergence retire) makes the next armed source recapture the WHOLE remote
# log from offset 0. Every line is already mirrored, so the at-most-once
# append adds no bytes, the adapter acknowledges the generation, and the
# self-announcing runner publishes nothing - the replay stays completely
# quiet, observed through the same seen-signature gate the watcher consumes.
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "could not prime the seen marker for the replay leg"
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-replay"
mv "$PARENT/state/.wake-queue" "$TMP_ROOT/wake-queue-before-replay" 2>/dev/null || true
stop_reply_listener || fail "the reply listener did not stop before the whole-log recapture"
rm -f "$PARENT/state/remote-replies/ios.cursor"
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the cursor-loss recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "the whole-log recapture was not acknowledged by the adapter"
# Documents that were undelivered when their lines first mirrored have since
# arrived, so this replay also pins that a line mirrors once whichever pointer
# form it was first written under.
cmp -s "$TMP_ROOT/ios-status-before-replay" "$PARENT/state/ios.status" \
  || fail "the whole-log recapture duplicated already-mirrored lines"
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID $GEN" "$PARENT/state/.wake-queue"; then
  fail "an already-mirrored recapture still published a check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "a byte-identical recapture left unannounced status bytes behind"
replay_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$replay_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recapture did not rebuild the lost cursor"
pass "a cursor-loss whole-log recapture is acknowledged quietly with no duplicate wake"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
stop_reply_listener || fail "the reply listener did not stop before the continuity break"
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
GEN=$((GEN + 1))
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.$GEN.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TWELVE")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" > "$TMP_ROOT/handle-nine.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_TWELVE" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
status_line_at_epoch "$(grep -F 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" >/dev/null \
  || fail "new continuity escalation has unknown emission time"
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf '\nNew continuity escalation after ingest retry:\n'
  grep -F 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status"
fi
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.$GEN.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "adapter retirement left a caught-up watermark a later route could inherit"
pass "remote reply retirement quiesces and refuses unhandled captured results"

# ---------------------------------------------------------------------------
# A sandbox task is the adapter's second route kind. Its one-task home's
# state/<id>.status mirrors into this home's state/<id>.status through the same
# cursor, normalization, and replay identity, while offered documents, corr=
# settlement, and the caught-up watermark stay secondmate-only, and a scout's
# terminal line fetches its fixed report first.
TASK_REMOTE="$TMP_ROOT/task-remote"
mkdir -p "$TASK_REMOTE/state" "$TASK_REMOTE/data/sbxship" "$TASK_REMOTE/data/sbxscout"
write_sandbox_record() { # <id> <ship|scout> [extra key=value...]
  local id=$1 kind=$2
  shift 2
  fm_write_meta "$PARENT/state/$id.meta" "window=remote:$id" "endpoint_task_id=$id" \
    "worktree=$TASK_REMOTE/projects/alpha-wt" "project=$PARENT/projects/alpha" "harness=pi" \
    "kind=$kind" "tasktmp=" "model=minimax/m2" "effort=default" "placement=sandbox" "remote_kind=task" \
    "remote_host=sbx-task" "remote_root=$ROOT" "remote_home=$TASK_REMOTE" "remote_backend=tmux" \
    "remote_target=firstmate:fm-$id" "sandbox_provider=pve-sandbox" "sandbox_name=sbx-$id" \
    "sandbox_profile=default" "$@"
}
await_source_result() { # <source-id> <result-path>
  local sid=$1 result=$2 handled=${2%.result}.handled owner
  owner=$(remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$sid" 'NR > 1 && $1 == id { print $3; exit }')
  if [ "$owner" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$sid" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 800); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  return 1
}
stop_source_listener() { # <source-id>
  local pid
  pid=$(sed -n '2p' "$CLAIMS/$1.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}
# capture_once <source-id> <label> [VAR=value...]: run one listener for a
# capture its adapter must leave unapplied or end, and fail rather than hang
# when the listener instead applies it and keeps listening.
capture_once() {
  local sid=$1 label=$2 runner assignment _
  shift 2
  (
    for assignment in "$@"; do export "${assignment?}"; done
    remote_env "$ROOT/bin/fm-procevent.sh" start "$sid"
  ) >/dev/null 2>&1 &
  runner=$!
  for _ in $(seq 1 600); do
    if ! kill -0 "$runner" 2>/dev/null; then
      wait "$runner" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  kill -TERM "$runner" 2>/dev/null || true
  stop_source_listener "$sid" || true
  fail "$label: the listener applied the capture and kept listening"
}
SHIP_GEN=0
mirror_ship_lines() { # <line>...
  SHIP_GEN=$((SHIP_GEN + 1))
  printf '%s\n' "$@" >> "$TASK_REMOTE/state/sbxship.status"
  await_source_result remote-reply-sbxship "$PARENT/state/procevent-inbox/remote-reply-sbxship.$SHIP_GEN.result" \
    || fail "sandbox ship generation $SHIP_GEN was not captured and applied"
}
SCOUT_GEN=0
mirror_scout_lines() { # <line>...
  SCOUT_GEN=$((SCOUT_GEN + 1))
  printf '%s\n' "$@" >> "$TASK_REMOTE/state/sbxscout.status"
  await_source_result remote-reply-sbxscout "$PARENT/state/procevent-inbox/remote-reply-sbxscout.$SCOUT_GEN.result" \
    || fail "sandbox scout generation $SCOUT_GEN was not captured and applied"
}
scout_note() { # <reason-fragment>: the scout's report-transfer note, stamps removed
  sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/sbxscout.status" \
    | grep -F "note: remote document did not transfer for sbxscout: data/sbxscout/report.md - $1"
}

write_sandbox_record sbxship ship mode=direct-PR yolo=off branch=fm/sbxship
write_sandbox_record sbxscout scout
assert_equals remote-reply-sbxship "$(remote_env "$ADAPTER" source-id sbxship)" \
  "a sandbox task's source id is the adapter's canonical one"
out=$(remote_env "$ADAPTER" arm sbxship)
assert_contains "$out" "armed: remote-reply-sbxship offset=0" "a sandbox task's mirror arms at the empty cursor"
grep -qxF "$ROOT/bin/fm-procevent-remote-reply.sh" "$PARENT/state/procevent/remote-reply-sbxship.source" \
  || fail "the armed task source does not run this adapter"
write_sandbox_record sbxbad ship mode=direct-PR yolo=off branch=fm/sbxbad "placement=sandbox"
set +e
out=$(remote_env "$ADAPTER" arm sbxbad 2>&1)
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] || fail "a task record with a repeated placement was armed"
assert_contains "$out" "must record placement= exactly once" "a malformed placement is refused with the route library's reason"
assert_absent "$PARENT/state/procevent/remote-reply-sbxbad.source" "a malformed placement registered a source"
rm -f "$PARENT/state/sbxbad.meta"
write_sandbox_record sbxdup ship mode=direct-PR yolo=off branch=fm/sbxdup
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/secondmates-before-dup"
printf -- '- sbxdup - duplicate route (host: remote-mac; root: %s; home: %s; scope: duplicate; projects: alpha; added 2026-10-02)\n' \
  "$ROOT" "$REMOTE" >> "$PARENT/data/secondmates.md"
set +e
out=$(remote_env "$ADAPTER" arm sbxdup 2>&1)
dup_rc=$?
set -e
[ "$dup_rc" -ne 0 ] || fail "an id that is both a sandbox task and a secondmate route was armed"
assert_contains "$out" "names a sandbox task and also a configured secondmate route" "the ambiguous route is named"
mv "$TMP_ROOT/secondmates-before-dup" "$PARENT/data/secondmates.md"
rm -f "$PARENT/state/sbxdup.meta"
pass "a sandbox task's status mirror arms from its record and refuses a malformed or ambiguous route"

# A ship's lines mirror verbatim into this home's own status log for that task.
printf '# a report the worker never offers\n' > "$TASK_REMOTE/data/sbxship/report.md"
SHIP_PENDING=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'a request only the secondmate may answer')
[ -n "$SHIP_PENDING" ] || fail "could not create the secondmate pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$SHIP_PENDING" \
  || fail "could not mark the secondmate request delivered"
mirror_ship_lines \
  'working [at=1700000400]: rebasing onto main' \
  "needs-decision [key=base] [at=1700000500]: keep or drop the shim? report=data/sbxship/report.md" \
  "working [corr=$SHIP_PENDING]: a sandbox line echoing another route's correlation" \
  $'blocked [key=ctl]: bell \007 here'
assert_grep 'working [at=1700000400]: rebasing onto main' "$PARENT/state/sbxship.status" \
  "the sandbox ship's progress line did not reach its status log"
assert_grep 'keep or drop the shim? report=data/sbxship/report.md' "$PARENT/state/sbxship.status" \
  "a sandbox line's pointer was rewritten as though it offered a document"
assert_absent "$PARENT/data/remote-secondmates/sbxship" "a sandbox task line fetched an offered document"
assert_grep 'blocked [key=ctl]: bell ? here' "$PARENT/state/sbxship.status" \
  "a sandbox line's control byte was not normalized"
printf '%s' "$(status_open_decisions "$PARENT/state/sbxship.status")" | grep -q '^base	needs-decision	' \
  || fail "the sandbox ship's decision is not open in this home's fold"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$SHIP_PENDING" phase)" != resolved ] \
  || fail "a sandbox task's line settled a secondmate's pending reply"
ship_offset=$(LC_ALL=C wc -c < "$TASK_REMOTE/state/sbxship.status" | tr -d ' ')
assert_grep "offset=$ship_offset" "$PARENT/state/remote-replies/sbxship.cursor" \
  "the sandbox ship's cursor did not advance to the end of its log"
[ ! -e "$PARENT/state/ios.status" ] \
  || assert_no_grep 'sbxship' "$PARENT/state/ios.status" "a sandbox task's lines leaked into another route's log"
remote_env "$ADAPTER" handle sbxship "$SHIP_GEN" \
  "$PARENT/state/procevent-inbox/remote-reply-sbxship.$SHIP_GEN.result" >/dev/null \
  || fail "replaying the sandbox ship's generation failed"
[ "$(grep -cF 'needs-decision [key=base]' "$PARENT/state/sbxship.status")" -eq 1 ] \
  || fail "replaying the sandbox ship's generation duplicated its decision"
stop_source_listener remote-reply-sbxship || fail "the sandbox ship's listener did not stop"
rm -f "$PARENT/state/remote-replies/sbxship.caught-up"
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source sbxship >/dev/null 2>&1
ship_quiet_rc=$?
set -e
[ "$ship_quiet_rc" -eq 75 ] || fail "a quiet sandbox window exited with an unexpected status: $ship_quiet_rc"
assert_absent "$PARENT/state/remote-replies/sbxship.caught-up" \
  "a sandbox task's quiet window published a reply watermark"
pass "a sandbox ship's lines mirror verbatim, offer nothing, settle nothing, and replay once"

# A scout's terminal line fetches its report into this home's data/<id>/ first.
out=$(remote_env "$ADAPTER" arm sbxscout)
assert_contains "$out" "armed: remote-reply-sbxscout offset=0" "the sandbox scout's mirror did not arm"
mirror_scout_lines 'working [at=1700000600]: reading the cache layer'
assert_absent "$PARENT/data/sbxscout/report.md" "a non-terminal scout line fetched a report"
head -c 300000 /dev/zero | tr '\0' 'r' > "$TASK_REMOTE/data/sbxscout/report.md"
mirror_scout_lines 'done [at=1700000700]: report ready'
cmp -s "$TASK_REMOTE/data/sbxscout/report.md" "$PARENT/data/sbxscout/report.md" \
  || fail "the scout's report, larger than a secondmate document's bound, did not arrive byte for byte"
assert_grep 'done [at=1700000700]: report ready' "$PARENT/state/sbxscout.status" "the scout's terminal line did not mirror"
assert_no_grep 'did not transfer' "$PARENT/state/sbxscout.status" "a delivered report left a transfer note"
printf '# revised after done\n' > "$TASK_REMOTE/data/sbxscout/report.md"
mirror_scout_lines 'needs-decision [key=scope] [at=1700000800]: widen the audit?'
[ "$(head -c 1 "$PARENT/data/sbxscout/report.md")" = r ] \
  || fail "a scout decision line refetched the report"
pass "a sandbox scout's terminal line fetches its report, beyond the document bound, before mirroring"

head -c 1048577 /dev/zero | tr '\0' 'o' > "$TASK_REMOTE/data/sbxscout/report.md"
mirror_scout_lines 'done [at=1700000900]: oversize report written'
scout_note 'file exceeds max-bytes' >/dev/null \
  || fail "an oversize scout report left no note naming the reader's refusal"
assert_grep 'done [at=1700000900]: oversize report written' "$PARENT/state/sbxscout.status" \
  "a refused report held the scout's terminal line back"
rm -f "$TASK_REMOTE/data/sbxscout/report.md"
mirror_scout_lines 'failed [at=1700001000]: could not reproduce'
scout_note 'file is not a non-symlink regular file' >/dev/null \
  || fail "a missing scout report left no note"
assert_grep 'failed [at=1700001000]: could not reproduce' "$PARENT/state/sbxscout.status" \
  "a missing report held the scout's failed line back"
if status_open_decisions "$PARENT/state/sbxscout.status" | grep -q 'remote-reply-'; then
  fail "a refused scout report opened a decision"
fi
scout_offset=$(LC_ALL=C wc -c < "$TASK_REMOTE/state/sbxscout.status" | tr -d ' ')
assert_grep "offset=$scout_offset" "$PARENT/state/remote-replies/sbxscout.cursor" \
  "a refused report held the scout's cursor back"
pass "a refused scout report fails open: the line mirrors, one note says why, and no decision opens"

stop_source_listener remote-reply-sbxscout || fail "the sandbox scout listener did not stop before hostile fetches"
for fetch_mode in oversized endless stderr stalled partial; do
  printf '%s\n' "$fetch_mode" > "$TMP_ROOT/fetch-mode"
  printf '# stale report\n' > "$PARENT/data/sbxscout/report.md"
  FM_REMOTE_REPLY_FETCH_SECONDS=3 mirror_scout_lines "done: hostile fetch $fetch_mode"
  assert_absent "$PARENT/data/sbxscout/report.md" "$fetch_mode installed or retained a report"
  assert_grep "done: hostile fetch $fetch_mode" "$PARENT/state/sbxscout.status" "$fetch_mode held the terminal line back"
  case "$fetch_mode" in
    oversized|endless) reason='remote document stdout exceeds max-bytes' ;;
    stderr) reason='remote document stderr exceeds max-bytes' ;;
    stalled) reason='remote document transfer timed out' ;;
    partial) reason='the remote reader gave no reason' ;;
  esac
  scout_note "$reason" >/dev/null || fail "$fetch_mode omitted the refusal note"
  if status_open_decisions "$PARENT/state/sbxscout.status" | grep -q 'remote-reply-'; then
    fail "$fetch_mode opened a decision"
  fi
  if compgen -G "$PARENT/data/sbxscout/.remote-doc.*" >/dev/null; then
    fail "$fetch_mode left a partial staging file"
  fi
done
rm -f "$TMP_ROOT/fetch-mode"
pass "primary bounds hostile stdout, stderr, endless and timed-out report transfers"

# A failure of the local receiver itself is a local storage failure, never a
# refusal: here a file-size limit, with its signal ignored so writing fails as
# a full disk does, stops the report write. The delta stays uncommitted for
# retry, no note is written, and the report already delivered is untouched.
stop_source_listener remote-reply-sbxscout || fail "the sandbox scout listener did not stop before the local failure"
LOCALFAIL_BIN="$TMP_ROOT/localfail-bin"
mkdir -p "$LOCALFAIL_BIN"
REAL_PERL=$(command -v perl)
{
  cat <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  if [ "$argument" = fm-remote-file.sh ]; then
    trap '' XFSZ
    ulimit -c 0
    ulimit -f 1
    break
  fi
done
SH
  printf 'exec %q "$@"\n' "$REAL_PERL"
} > "$LOCALFAIL_BIN/perl"
chmod +x "$LOCALFAIL_BIN/perl"
head -c 8192 /dev/zero | tr '\0' 'L' > "$TASK_REMOTE/data/sbxscout/report.md"
printf '# report delivered earlier\n' > "$PARENT/data/sbxscout/report.md"
localfail_cursor_before=$(cat "$PARENT/state/remote-replies/sbxscout.cursor")
localfail_notes_before=$(grep -c 'did not transfer' "$PARENT/state/sbxscout.status" || true)
printf 'done [at=1700001050]: report rewritten\n' >> "$TASK_REMOTE/state/sbxscout.status"
SCOUT_GEN=$((SCOUT_GEN + 1))
capture_once remote-reply-sbxscout "a local receiver failure" "PATH=$LOCALFAIL_BIN:$PATH"
SCOUT_LOCALFAIL="$PARENT/state/procevent-inbox/remote-reply-sbxscout.$SCOUT_GEN.result"
assert_present "$SCOUT_LOCALFAIL" "the terminal line behind the local failure was not captured"
assert_absent "${SCOUT_LOCALFAIL%.result}.handled" "a capture whose local receiver failed was acknowledged"
assert_no_grep 'report rewritten' "$PARENT/state/sbxscout.status" "a local receiver failure mirrored the line as though refused"
assert_equals "$localfail_notes_before" "$(grep -c 'did not transfer' "$PARENT/state/sbxscout.status" || true)" \
  "a local receiver failure wrote a refusal note"
assert_equals '# report delivered earlier' "$(cat "$PARENT/data/sbxscout/report.md")" \
  "a local receiver failure removed or replaced the delivered report"
[ "$(cat "$PARENT/state/remote-replies/sbxscout.cursor")" = "$localfail_cursor_before" ] \
  || fail "a local receiver failure advanced the scout's cursor"
if compgen -G "$PARENT/data/sbxscout/.remote-doc.*" >/dev/null; then
  fail "a local receiver failure left a partial staging file"
fi
MISSING_HELPER_ROOT="$TMP_ROOT/missing-helper"
mkdir -p "$MISSING_HELPER_ROOT"
cp -R "$ROOT/bin" "$MISSING_HELPER_ROOT/bin"
rm "$MISSING_HELPER_ROOT/bin/fm-on.sh"
if remote_env "$MISSING_HELPER_ROOT/bin/fm-procevent-remote-reply.sh" handle sbxscout "$SCOUT_GEN" "$SCOUT_LOCALFAIL" >/dev/null; then
  fail "missing local fm-on.sh accepted the delta"
fi
assert_equals '# report delivered earlier' "$(cat "$PARENT/data/sbxscout/report.md")" \
  "missing local fm-on.sh removed the report"
assert_equals "$localfail_cursor_before" "$(cat "$PARENT/state/remote-replies/sbxscout.cursor")" \
  "missing local fm-on.sh committed the delta"
assert_no_grep 'report rewritten' "$PARENT/state/sbxscout.status" "missing helper mirrored a terminal line"
assert_equals "$localfail_notes_before" "$(grep -c 'did not transfer' "$PARENT/state/sbxscout.status" || true)" \
  "missing helper wrote a remote refusal note"
remote_env "$ADAPTER" handle sbxscout "$SCOUT_GEN" "$SCOUT_LOCALFAIL" >/dev/null \
  || fail "the scout's capture did not apply once the local receiver recovered"
cmp -s "$TASK_REMOTE/data/sbxscout/report.md" "$PARENT/data/sbxscout/report.md" \
  || fail "the recovered fetch did not deliver the rewritten report"
assert_grep 'report rewritten' "$PARENT/state/sbxscout.status" "the recovered terminal line did not mirror"
pass "a failing local receiver keeps the scout's delta uncommitted and its delivered report untouched"

# Transport loss while fetching leaves the whole delta uncommitted for retry,
# so the terminal line never lands ahead of its report.
stop_source_listener remote-reply-sbxscout || fail "the sandbox scout's listener did not stop"
printf '# final findings\n' > "$TASK_REMOTE/data/sbxscout/report.md"
scout_cursor_before=$(cat "$PARENT/state/remote-replies/sbxscout.cursor")
printf 'done [at=1700001100]: final report ready\n' >> "$TASK_REMOTE/state/sbxscout.status"
SCOUT_GEN=$((SCOUT_GEN + 1))
capture_once remote-reply-sbxscout "a lost report fetch" FM_REMOTE_REPLY_FAIL_FILE=1
SCOUT_LOST="$PARENT/state/procevent-inbox/remote-reply-sbxscout.$SCOUT_GEN.result"
assert_present "$SCOUT_LOST" "the scout's terminal line was not captured"
assert_absent "${SCOUT_LOST%.result}.handled" "a capture whose report fetch lost its transport was acknowledged"
assert_no_grep 'final report ready' "$PARENT/state/sbxscout.status" "the terminal line landed while its report was in doubt"
[ "$(cat "$PARENT/state/remote-replies/sbxscout.cursor")" = "$scout_cursor_before" ] \
  || fail "a lost report fetch advanced the scout's cursor"
assert_grep "procevent remote-reply remote-reply-sbxscout $SCOUT_GEN" "$PARENT/state/.wake-queue" \
  "an unapplied scout capture lost its check wake"
remote_env "$ADAPTER" handle sbxscout "$SCOUT_GEN" "$SCOUT_LOST" >/dev/null \
  || fail "the scout's capture did not apply once the transport returned"
assert_equals '# final findings' "$(cat "$PARENT/data/sbxscout/report.md")" "the retried fetch did not deliver the final report"
assert_grep 'final report ready' "$PARENT/state/sbxscout.status" "the retried terminal line did not mirror"
pass "a lost report fetch keeps the scout's terminal line uncommitted until the report arrives"

# A sandbox task's continuity break names the task's mirror.
stop_source_listener remote-reply-sbxship || fail "the sandbox ship's listener did not stop before the break"
printf 'working: replaced log\n' > "$TASK_REMOTE/state/sbxship.status"
SHIP_GEN=$((SHIP_GEN + 1))
capture_once remote-reply-sbxship "a broken sandbox mirror"
sed -E 's/ \[at=[0-9]+\]//' "$PARENT/state/sbxship.status" \
  | grep -qF 'blocked [key=remote-reply-continuity-sbxship]: status mirror continuity broke for sandbox task sbxship (truncated)' \
  || fail "a sandbox task's continuity break was not escalated as its mirror's"
assert_absent "$PARENT/state/procevent/remote-reply-sbxship.source" "a broken sandbox mirror was re-armed"
pass "a sandbox task's continuity break escalates once and is not silently rebased"

echo "ALL TESTS PASSED"
