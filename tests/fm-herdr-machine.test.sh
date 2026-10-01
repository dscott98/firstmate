#!/usr/bin/env bash
# tests/fm-herdr-machine.test.sh - the primary-side saved-machine save that
# keeps remote second-mate hosts visible in the local Herdr
# (bin/fm-herdr-machine-lib.sh).
#
# Every herdr call in this suite goes to a fake CLI: the runner's real Herdr
# and its real saved machines are never read or changed here. The fake owns
# the machine-list contents and whether machine add accepts or refuses, and
# logs every argv, so the suite pins the exact save command, its idempotence,
# and the never-rewrite rule for machines Firstmate did not add.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the save parses herdr's JSON list)"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-herdr-machine)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_cleanup || true' EXIT

# make_herdr_fake <dir>: a fake herdr whose machine list is the contents of
# $FM_FAKE_HERDR_MACHINES, whose machine add fails with the message stored in
# $FM_FAKE_HERDR_ADD_REFUSE when that file is non-empty, and which logs every
# argv to $FM_FAKE_HERDR_LOG.
make_herdr_fake() {
  local dir=$1
  mkdir -p "$dir"
  ln -sf "$(command -v jq)" "$dir/jq"
  cat > "$dir/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "machine list")
    cat "${FM_FAKE_HERDR_MACHINES:?}" 2>/dev/null || printf '[]\n'
    exit 0
    ;;
  "machine add")
    if [ -s "${FM_FAKE_HERDR_ADD_REFUSE:-}" ]; then
      cat "${FM_FAKE_HERDR_ADD_REFUSE}" >&2
      exit 1
    fi
    jq --arg a "$7" --arg s "$6" \
      '. + [{id: "added", label: $a, target: $a, session: $s, enabled: true}]' \
      "$FM_FAKE_HERDR_MACHINES" > "$FM_FAKE_HERDR_MACHINES.tmp"
    mv "$FM_FAKE_HERDR_MACHINES.tmp" "$FM_FAKE_HERDR_MACHINES"
    printf 'machine saved\n'
    exit 0
    ;;
  "machine remove")
    [ ! -s "${FM_FAKE_HERDR_ADD_REFUSE}.remove" ] || exit 1
    jq --arg id "$3" 'map(select(.id != $id))' "$FM_FAKE_HERDR_MACHINES" > "$FM_FAKE_HERDR_MACHINES.tmp"
    mv "$FM_FAKE_HERDR_MACHINES.tmp" "$FM_FAKE_HERDR_MACHINES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$dir/herdr"
}

# make_world <name> [no-herdr]: one home state directory plus the fake herdr,
# an empty machine list, an empty refusal file, and an empty call log.
make_world() {
  local name=$1 no_herdr=${2:-}
  local w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/fakebin"
  if [ "$no_herdr" = no-herdr ]; then
    ln -sf "$(command -v jq)" "$w/fakebin/jq"
    ln -sf "$(command -v bash)" "$w/fakebin/bash"
    ln -sf "$(command -v dirname)" "$w/fakebin/dirname"
    ln -sf "$(command -v sed)" "$w/fakebin/sed"
    touch "$w/no-herdr"
  else
    make_herdr_fake "$w/fakebin"
  fi
  printf '[]\n' > "$w/machines.json"
  : > "$w/add-refuse"
  : > "$w/herdr.log"
  printf '%s\n' "$w"
}

# ensure <world> <alias> [session] -> "<result>|<stdout-first>|<stderr-first>"
# on one line; the save itself always exits 0, so its outcome travels through
# FM_HERDR_MACHINE_RESULT and its printed report.
ensure() {
  local w=$1 alias=$2 session=${3:-fm-remote} test_path
  test_path="$w/fakebin:/usr/bin:/bin"
  [ ! -e "$w/no-herdr" ] || test_path="$w/fakebin"
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" \
    FM_FAKE_HERDR_LOG="$w/herdr.log" \
    FM_FAKE_HERDR_MACHINES="$w/machines.json" \
    FM_FAKE_HERDR_ADD_REFUSE="$w/add-refuse" \
    PATH="$test_path" \
    bash -c '
      . "$1/bin/fm-herdr-machine-lib.sh"
      : > "$2/out"; : > "$2/err"
      fm_herdr_machine_saved_ensure "$3" "$4" > "$2/out" 2> "$2/err" && rc=0 || rc=$?
      [ "$rc" -eq 0 ] || printf "ensure-exit=%s\n" "$rc"
      printf "%s|%s|%s\n" "${FM_HERDR_MACHINE_RESULT:-}" "$(sed -n 1p "$2/out")" "$(sed -n 1p "$2/err")"
    ' _ "$ROOT" "$w" "$alias" "$session"
}

# --- no local herdr means no save at all -------------------------------------

w=$(make_world absent-herdr no-herdr)
out=$(ensure "$w" agent07)
[ "$out" = 'absent_herdr||' ] || fail "an absent herdr did not skip silently: $out"
[ ! -s "$w/herdr.log" ] || fail "an absent herdr still called something: $(cat "$w/herdr.log")"
pass "an absent local herdr skips the save silently"

# --- an existing machine for the alias is left alone -------------------------

w=$(make_world present)
cat > "$w/machines.json" <<'EOF'
[
  {"id":"one","label":"captain-mac","target":"captain-mac","session":"fm-remote","enabled":true,"selected":false},
  {"id":"two","label":"agent07","target":"agent07","session":"fm-remote","enabled":true,"selected":false}
]
EOF
out=$(ensure "$w" agent07)
[ "$out" = 'present||' ] || fail "an existing correct machine was not a silent no-op: $out"
[ "$(cat "$w/herdr.log")" = 'machine list --json' ] || fail "an existing correct machine was changed"
[ ! -e "$w/home/state/.herdr-machine-agent07.json" ] || fail "an existing foreign machine gained ownership"
pass "an enabled machine for the required session is a silent no-op"

# --- an existing machine under another session is reported, never rewritten --

w=$(make_world mismatch)
cat > "$w/machines.json" <<'EOF'
[{"id":"one","label":"agent07","target":"agent07","session":"personal","enabled":true,"selected":false}]
EOF
out=$(ensure "$w" agent07)
[ "$out" = 'mismatch||warning: saved herdr machine agent07 has {"session":"personal","enabled":true}, expected enabled session fm-remote; left unchanged; run: herdr machine remove one; herdr machine add --label agent07 --remote-session fm-remote agent07' ] \
  || fail "a foreign-session machine was not reported as left unchanged: $out"
assert_no_grep 'machine add' "$w/herdr.log" "a foreign-session machine was rewritten"
pass "a machine saved under another session is reported and never rewritten"
assert_no_grep 'machine remove' "$w/herdr.log" "a foreign machine was removed"
[ "$(wc -l < "$w/err")" -eq 1 ] || fail "foreign mismatch emitted multiple warning lines"

w=$(make_world foreign-disabled)
printf '[{"id":"foreign","target":"agent07","session":"fm-remote","enabled":false}]\n' > "$w/machines.json"
out=$(ensure "$w" agent07)
[ "$out" = 'mismatch||warning: saved herdr machine agent07 has {"session":"fm-remote","enabled":false}, expected enabled session fm-remote; left unchanged; run: herdr machine remove foreign; herdr machine add --label agent07 --remote-session fm-remote agent07' ] || fail "disabled foreign machine warning: $out"
[ "$(cat "$w/herdr.log")" = 'machine list --json' ] || fail "disabled foreign machine was changed"
pass "a disabled foreign machine is left untouched with repair commands"

for change in disabled wrong-session; do
  w=$(make_world "own-$change")
  ensure "$w" agent07 >/dev/null
  jq -e '.alias == "agent07" and .session == "fm-remote"' \
    "$w/home/state/.herdr-machine-agent07.json" >/dev/null || fail "successful add did not record ownership"
  if [ "$change" = disabled ]; then
    jq '.[0].enabled = false' "$w/machines.json" > "$w/changed.json"
  else
    jq '.[0].session = "personal"' "$w/machines.json" > "$w/changed.json"
  fi
  mv "$w/changed.json" "$w/machines.json"
  : > "$w/herdr.log"
  out=$(ensure "$w" agent07)
  [ "$out" = 'added|saved herdr machine agent07 (remote session fm-remote)|' ] || fail "own $change machine did not converge: $out"
  [ "$(cat "$w/herdr.log")" = 'machine list --json
machine remove added
machine add --label agent07 --remote-session fm-remote agent07' ] || fail "own $change repair commands differed"
  jq -e 'length == 1 and .[0].enabled == true and .[0].session == "fm-remote"' "$w/machines.json" >/dev/null || fail "own $change machine remains mismatched"
  out=$(ensure "$w" agent07)
  [ "$out" = 'present||' ] || fail "own $change repair was not idempotent: $out"
  pass "an owned $change machine converges and stays idempotent"
done

w=$(make_world remove-failed)
ensure "$w" agent07 >/dev/null
jq '.[0].enabled = false' "$w/machines.json" > "$w/changed.json"
mv "$w/changed.json" "$w/machines.json"
printf 'refuse\n' > "$w/add-refuse.remove"
: > "$w/herdr.log"
out=$(ensure "$w" agent07)
[[ "$out" == refused\|\|warning:* ]] || fail "failed removal was not best-effort: $out"
assert_no_grep 'machine add' "$w/herdr.log" "failed removal still added a machine"
pass "failed removal warns without adding or failing the caller"


# --- a missing machine is added with the exact save command ------------------

w=$(make_world added)
out=$(ensure "$w" agent07)
[ "$out" = 'added|saved herdr machine agent07 (remote session fm-remote)|' ] \
  || fail "a missing machine was not saved with a report line: $out"
assert_grep 'machine list --json' "$w/herdr.log" "the save did not read the machine list first"
assert_grep 'machine add --label agent07 --remote-session fm-remote agent07' "$w/herdr.log" \
  "the save did not run the exact machine add command"
pass "a missing machine is added through the exact idempotent save command"

w=$(make_world added-custom-session)
out=$(ensure "$w" agent08 other-session)
[ "$out" = 'added|saved herdr machine agent08 (remote session other-session)|' ] \
  || fail "a custom remote session was not passed through: $out"
assert_grep 'machine add --label agent08 --remote-session other-session agent08' "$w/herdr.log" \
  "the custom remote session did not reach machine add"
pass "the save passes the route's remote session through"

# --- a refused add is reported and never fails the caller --------------------

w=$(make_world refused)
printf 'error: remote server is not ready for saved machines\n' > "$w/add-refuse"
out=$(ensure "$w" agent07)
[ "$out" = 'refused||warning: herdr machine agent07 was not saved: error: remote server is not ready for saved machines' ] \
  || fail "a refused add was not reported as a warning: $out"
[ ! -e "$w/home/state/.herdr-machine-agent07.json" ] || fail "refused add claimed ownership"
pass "a refused add reports the refusal and still succeeds"

# --- an unreadable machine list is reported and adds nothing -----------------

w=$(make_world list-failed)
printf 'not json at all\n' > "$w/machines.json"
out=$(ensure "$w" agent07)
[ "$out" = 'list_failed||warning: the saved herdr machines could not be parsed, so agent07 was not saved' ] \
  || fail "an unparseable machine list was not reported: $out"
assert_no_grep 'machine add' "$w/herdr.log" "an unparseable machine list still triggered an add"
pass "an unreadable machine list is reported and never blind-adds"

# --- a second ensure while the per-alias lock is held skips quietly ----------

w=$(make_world locked)
mkdir -p "$w/home/state"
# Hold the exact lock the save takes for this alias.
# shellcheck disable=SC2016 # positional params expand in the child shell.
env STATE="$w/home/state" PATH="$w/fakebin:/usr/bin:/bin" \
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$STATE/.herdr-machine-agent07.lock" >/dev/null 2>&1 || fm_lock_try_acquire "$STATE/.herdr-machine-agent07.lock" || exit 1; sleep 5' _ "$ROOT" &
holder=$!
sleep 0.3
out=$(ensure "$w" agent07)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[ "$out" = 'busy||' ] || fail "a held per-alias lock did not skip quietly: $out"
assert_no_grep 'machine add' "$w/herdr.log" "a held lock still added a machine"
pass "a concurrent save for the same alias skips quietly under its lock"


