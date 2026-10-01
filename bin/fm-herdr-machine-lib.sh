#!/usr/bin/env bash
# fm-herdr-machine-lib.sh - keep remote second-mate hosts visible in the
# primary's local Herdr as saved machines.
#
# A remote second mate always runs on the Herdr backend in its host's fm-remote
# session (docs/remote-secondmates.md). Herdr's saved SSH machines make that
# remote activity visible in the local sidebar, so Firstmate performs the save
# itself rather than leaving it to a manual per-host step:
#
#   - bin/fm-spawn.sh saves the host after a remote second mate is launched,
#   - bin/fm-secondmate-liveness-lib.sh saves it after a remote route is found
#     alive, so a rebuilt or reinstalled local Herdr converges on the next
#     supervision pass.
#
# fm_herdr_machine_saved_ensure <host-alias> <session> is the single owner of
# that save and is idempotent and best-effort:
#
#   - With no local herdr (or no jq to parse its list output) it skips
#     silently: a primary that does not run Herdr saves nothing.
#   - A refused add (for example a remote server too old to serve saved
#     machines) is reported as a warning and never fails the launch or probe
#     around it; bin/fm-remote-doctor.sh owns reporting the host upgrade that
#     fixes the refusal.
#
# The per-alias lock serializes concurrent ensures for mates that share one
# host; a busy lock skips quietly because its holder is performing this same
# save. FM_HERDR_MACHINE_RESULT carries the last outcome (absent_herdr,
# absent_jq, busy, present, mismatch, list_failed, added, refused, record_failed) for
# callers and tests.

FM_HERDR_MACHINE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Generous bound for one herdr machine call: the save normally follows a
# confirmed-reachable host, so this only caps a wedged SSH transport.
FM_HERDR_MACHINE_CALL_TIMEOUT_SECS=60
FM_HERDR_MACHINE_RESULT=

fm_herdr_machine_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_HERDR_MACHINE_LIB_DIR/fm-wake-lib.sh"
}

fm_herdr_machine_require_timeout() {
  command -v fm_run_timed >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_HERDR_MACHINE_LIB_DIR/fm-timeout-lib.sh"
}

# fm_herdr_machine_saved_ensure <host-alias> [<session>]
# Best-effort and idempotent; always returns 0 so provisioning and liveness
# never fail over a local visibility save. Reports one line on stdout when a
# machine is added and one warning on stderr when a save is impossible or
# refused; a correct entry and an absent local herdr stay silent.
fm_herdr_machine_saved_ensure() { # <host-alias> [<session>]
  local alias=$1 session=${2:-fm-remote} herdr_bin jq_bin key lock list rc matches
  local entry entry_id add_out reason record record_tmp repair_command
  FM_HERDR_MACHINE_RESULT=present
  herdr_bin=$(command -v herdr 2>/dev/null || true)
  if [ -z "$herdr_bin" ] || [ ! -x "$herdr_bin" ]; then
    FM_HERDR_MACHINE_RESULT=absent_herdr
    return 0
  fi
  jq_bin=$(command -v jq 2>/dev/null || true)
  if [ -z "$jq_bin" ] || [ ! -x "$jq_bin" ]; then
    FM_HERDR_MACHINE_RESULT=absent_jq
    return 0
  fi
  fm_herdr_machine_require_timeout || true
  key=$(printf '%s' "$alias" | sed 's/[^A-Za-z0-9._-]/_/g')
  [ -n "$key" ] || key=host
  lock="$STATE/.herdr-machine-$key.lock"
  record="$STATE/.herdr-machine-$key.json"
  if ! fm_herdr_machine_require_locks || ! fm_lock_try_acquire "$lock"; then
    FM_HERDR_MACHINE_RESULT=busy
    return 0
  fi
  list=$(fm_run_timed "$FM_HERDR_MACHINE_CALL_TIMEOUT_SECS" \
    "$herdr_bin" machine list --json < /dev/null 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      reason="herdr machine list timed out after ${FM_HERDR_MACHINE_CALL_TIMEOUT_SECS}s"
    else
      reason="herdr machine list failed with exit $rc"
    fi
    echo "warning: the saved herdr machines could not be read, so $alias was not saved: $reason" >&2
    FM_HERDR_MACHINE_RESULT=list_failed
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi
  if ! matches=$(printf '%s' "$list" | jq -ce --arg t "$alias" \
    '[.[] | select(.target == $t)]' 2>/dev/null); then
    echo "warning: the saved herdr machines could not be parsed, so $alias was not saved" >&2
    FM_HERDR_MACHINE_RESULT=list_failed
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi
  if printf '%s' "$matches" | jq -e --arg s "$session" \
    'any(.[]; .session == $s and .enabled == true)' >/dev/null; then
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi
  entry=$(printf '%s' "$matches" | jq -c '.[0] // empty')
  if [ -n "$entry" ]; then
    entry_id=$(printf '%s' "$entry" | jq -r '.id // empty')
    reason=$(printf '%s' "$entry" | jq -c '{session, enabled}')
    printf -v repair_command 'herdr machine remove %q; herdr machine add --label %q --remote-session %q %q' \
      "$entry_id" "$alias" "$session" "$alias"
    if [ -z "$entry_id" ] || ! jq -e --arg t "$alias" \
      '.alias == $t and (.session | type == "string")' "$record" >/dev/null 2>&1; then
      echo "warning: saved herdr machine $alias has $reason, expected enabled session $session; left unchanged; run: $repair_command" >&2
      FM_HERDR_MACHINE_RESULT=mismatch
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    if ! fm_run_timed "$FM_HERDR_MACHINE_CALL_TIMEOUT_SECS" \
      "$herdr_bin" machine remove "$entry_id" < /dev/null >/dev/null 2>&1; then
      echo "warning: saved herdr machine $alias has $reason; removal failed; run: $repair_command" >&2
      FM_HERDR_MACHINE_RESULT=refused
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
  fi
  record_tmp=$(mktemp "$record.XXXXXX")
  if [ -z "$record_tmp" ] || ! jq -n --arg a "$alias" --arg s "$session" \
    '{alias: $a, session: $s}' > "$record_tmp"; then
    [ -z "$record_tmp" ] || rm -f "$record_tmp"
    echo "warning: herdr machine $alias was not saved: ownership record could not be prepared" >&2
    FM_HERDR_MACHINE_RESULT=record_failed
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi
  add_out=$(fm_run_timed "$FM_HERDR_MACHINE_CALL_TIMEOUT_SECS" \
    "$herdr_bin" machine add --label "$alias" --remote-session "$session" "$alias" < /dev/null 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # shellcheck disable=SC2034 # Read by sourcing callers and tests as the save's outcome word.
    FM_HERDR_MACHINE_RESULT=added
    if ! mv -f "$record_tmp" "$record"; then
      FM_HERDR_MACHINE_RESULT=record_failed
      echo "warning: herdr machine $alias was saved but its ownership record could not be published" >&2
    fi
    echo "saved herdr machine $alias (remote session $session)"
  else
    # shellcheck disable=SC2034 # Read by sourcing callers and tests as the save's outcome word.
    FM_HERDR_MACHINE_RESULT=refused
    reason=$(printf '%s\n' "$add_out" | sed -n '1p')
    if fm_timed_out "$rc"; then
      reason="timed out after ${FM_HERDR_MACHINE_CALL_TIMEOUT_SECS}s"
    fi
    [ -n "$reason" ] || reason="herdr machine add exited $rc"
    echo "warning: herdr machine $alias was not saved: $reason" >&2
  fi
  rm -f "$record_tmp"
  fm_lock_release "$lock" 2>/dev/null || true
  return 0
}
