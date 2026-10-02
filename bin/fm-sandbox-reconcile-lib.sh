#!/usr/bin/env bash
# shellcheck disable=SC2034 # Inventory and record fields are output globals for sourcing callers.
# fm-sandbox-reconcile-lib.sh - the single owner of reconciling this home's
# sandbox task records with the sandbox provider's inventory: reading that
# inventory, the destroy-pending record a landed teardown keeps while it still
# owes a sandbox its destroy, and that label-confirmed destroy itself.
# bin/fm-teardown.sh destroys a sandbox task's sandbox through it once the
# task's landed-work gate has passed, and bin/fm-bootstrap.sh retries what a
# teardown left pending, renews recorded sandboxes' TTLs, and reports the
# sandboxes no record names; docs/remote-sandboxes.md owns the operator view.
# Every provider call goes through bin/fm-sandbox.sh, whose header owns the
# record framing and exit contracts, with this home's FM_HOME and config
# directory named explicitly.
#
# Source it after resolving FM_HOME, STATE, and CONFIG, then call:
#
# fm_sandbox_inventory_read
#   Reads `fm-sandbox.sh list` - this home's sandboxes only, validated - into
#   FM_SANDBOX_INVENTORY, one record line per sandbox. Returns 1 with
#   FM_SANDBOX_ERROR naming why when the inventory cannot be read: no provider
#   configured, a provider failure or capacity refusal, or invalid output. An
#   unreadable inventory proves nothing about any sandbox.
# fm_sandbox_inventory_lookup <name>
#   After a successful read, 0 when the inventory lists <name> exactly once as
#   running or stopped, with FM_SANDBOX_INV_TASK holding its fm_task label and
#   FM_SANDBOX_INV_STATE its state; 1 when it is not listed, which means absent
#   or labelled for another home; 2 when it is listed more than once.
# fm_sandbox_record_field <record> <key>
#   Prints one field of a provider record line; 1 when the line has none.
# fm_sandbox_name_valid <name>
#   0 for a value the adapter accepts as a sandbox name: a non-empty printable
#   token without whitespace, "=", or a leading "-".
#
# The destroy-pending record is state/<id>.sandbox-destroy-pending, holding
# exactly the two lines task_id=<id> and sandbox_name=<name>. It authorizes one
# thing only: destroying that sandbox with --expect-task <id>. Teardown writes
# it only after the task's landed-work gate has passed or --force recorded the
# captain's discard, and before it records the backlog close or removes the
# task record, so a crash or a failed destroy never leaves a released sandbox
# that nothing names. A successful destroy removes it; while the task's record
# still names that same sandbox, nothing acts on it but a rerun of teardown.
# fm_sandbox_destroy_pending_path <id>
# fm_sandbox_destroy_pending_write <id> <name>
# fm_sandbox_destroy_pending_read <path>
#   Validates one record: a regular file named for its task, holding one
#   task_id equal to that name and one valid sandbox_name, and nothing else.
#   Sets FM_SANDBOX_PENDING_TASK and FM_SANDBOX_PENDING_NAME, or returns 1 with
#   FM_SANDBOX_ERROR.
# fm_sandbox_destroy <id> <name>
#   Runs `fm-sandbox.sh destroy <name> --expect-task <id>`, whose provider
#   refuses a sandbox whose labels disagree and treats an absent one as
#   destroyed, then removes the task's destroy-pending record. Returns 1 with
#   FM_SANDBOX_ERROR, keeping that record, when the destroy fails.
# fm_sandbox_renew <name>
#   Renews the sandbox's TTL with the provider's configured default
#   (`fm-sandbox.sh extend <name>`); returns 1 with FM_SANDBOX_ERROR.

FM_SANDBOX_RECONCILE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-backend.sh
. "$FM_SANDBOX_RECONCILE_LIB_DIR/fm-backend.sh"

FM_SANDBOX_INVENTORY=
FM_SANDBOX_INV_TASK=
FM_SANDBOX_INV_STATE=
FM_SANDBOX_PENDING_TASK=
FM_SANDBOX_PENDING_NAME=
FM_SANDBOX_ERROR=
FM_SANDBOX_OUT=
FM_SANDBOX_ERR=

fm_sandbox_name_valid() { # <name>
  case "$1" in
    ''|-*|*[[:space:]]*|*=*|*[![:print:]]*) return 1 ;;
  esac
  return 0
}

# One adapter call with stdout and stderr kept apart, because the adapter
# forwards a successful provider's stderr as diagnostics beside its records.
fm_sandbox_capture() { # <verb> [args...]
  local err rc=0
  FM_SANDBOX_OUT=
  FM_SANDBOX_ERR=
  err=$(mktemp "${TMPDIR:-/tmp}/fm-sandbox-reconcile.XXXXXX") || {
    FM_SANDBOX_ERR="cannot create a temporary file for the sandbox adapter's diagnostics"
    return 1
  }
  FM_SANDBOX_OUT=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$FM_SANDBOX_RECONCILE_LIB_DIR/fm-sandbox.sh" "$@" </dev/null 2>"$err") || rc=$?
  FM_SANDBOX_ERR=$(cat "$err" 2>/dev/null || true)
  rm -f -- "$err"
  return "$rc"
}

# The adapter's refusal as one printable line, for a diagnostic or a refusal.
fm_sandbox_reason() { # <adapter-stderr>
  local line=${1%%$'\n'*}
  line=${line#refused: }
  line=${line#blocked: }
  line=$(printf '%s' "$line" | LC_ALL=C tr -c '[:print:]' '?')
  [ "${#line}" -le 300 ] || line="${line:0:297}..."
  printf '%s' "${line:-the sandbox adapter gave no reason}"
}

fm_sandbox_record_field() { # <record> <key>
  local field
  local -a fields=()
  read -r -a fields <<<"$1"
  for field in "${fields[@]+"${fields[@]}"}"; do
    case "$field" in
      "$2="*) printf '%s\n' "${field#*=}"; return 0 ;;
    esac
  done
  return 1
}

fm_sandbox_inventory_read() {
  FM_SANDBOX_INVENTORY=
  FM_SANDBOX_ERROR=
  if ! fm_sandbox_capture list; then
    FM_SANDBOX_ERROR=$(fm_sandbox_reason "$FM_SANDBOX_ERR")
    return 1
  fi
  FM_SANDBOX_INVENTORY=$FM_SANDBOX_OUT
}

fm_sandbox_inventory_lookup() { # <name>
  local line name state found=0
  FM_SANDBOX_INV_TASK=
  FM_SANDBOX_INV_STATE=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(fm_sandbox_record_field "$line" name) || continue
    [ "$name" = "$1" ] || continue
    state=$(fm_sandbox_record_field "$line" state) || state=
    case "$state" in running|stopped) ;; *) continue ;; esac
    found=$((found + 1))
    FM_SANDBOX_INV_STATE=$state
    FM_SANDBOX_INV_TASK=$(fm_sandbox_record_field "$line" fm_task) || FM_SANDBOX_INV_TASK=
  done <<EOF
$FM_SANDBOX_INVENTORY
EOF
  case "$found" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  FM_SANDBOX_INV_TASK=
  FM_SANDBOX_INV_STATE=
  return 2
}

fm_sandbox_destroy_pending_path() { # <id>
  # shellcheck disable=SC2153 # STATE is the sourcing caller's state directory.
  printf '%s/%s.sandbox-destroy-pending\n' "$STATE" "$1"
}

fm_sandbox_destroy_pending_write() { # <id> <name>
  local path tmp
  path=$(fm_sandbox_destroy_pending_path "$1")
  [ ! -d "$path" ] || return 1
  tmp="$path.tmp.$$"
  if ! (umask 077; printf 'task_id=%s\nsandbox_name=%s\n' "$1" "$2" > "$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
}

fm_sandbox_destroy_pending_read() { # <path>
  local path=$1 base id task name lines
  FM_SANDBOX_PENDING_TASK=
  FM_SANDBOX_PENDING_NAME=
  FM_SANDBOX_ERROR=
  base=${path##*/}
  id=${base%.sandbox-destroy-pending}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      FM_SANDBOX_ERROR="its file name names no valid task id"
      return 1
      ;;
  esac
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    FM_SANDBOX_ERROR="it is not a regular file"
    return 1
  fi
  lines=$(LC_ALL=C grep -c '' "$path" 2>/dev/null || true)
  task=$(fm_backend_meta_exact_value "$path" task_id) || task=
  name=$(fm_backend_meta_exact_value "$path" sandbox_name) || name=
  if [ "$lines" != 2 ] || [ "$task" != "$id" ] || ! fm_sandbox_name_valid "$name"; then
    FM_SANDBOX_ERROR="it does not hold exactly task_id=$id and one valid sandbox_name"
    return 1
  fi
  FM_SANDBOX_PENDING_TASK=$task
  FM_SANDBOX_PENDING_NAME=$name
}

fm_sandbox_destroy() { # <id> <name>
  FM_SANDBOX_ERROR=
  if ! fm_sandbox_capture destroy "$2" --expect-task "$1"; then
    FM_SANDBOX_ERROR=$(fm_sandbox_reason "$FM_SANDBOX_ERR")
    return 1
  fi
  if ! rm -f -- "$(fm_sandbox_destroy_pending_path "$1")"; then
    FM_SANDBOX_ERROR="the sandbox was destroyed, but its destroy-pending record could not be removed"
    return 1
  fi
}

fm_sandbox_renew() { # <name>
  FM_SANDBOX_ERROR=
  if ! fm_sandbox_capture extend "$1"; then
    FM_SANDBOX_ERROR=$(fm_sandbox_reason "$FM_SANDBOX_ERR")
    return 1
  fi
}
