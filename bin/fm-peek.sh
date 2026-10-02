#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# bin/fm-remote-route-lib.sh decides whether the selected record is remotely
# placed. A remote secondmate's or sandbox task's pane lives on its host, so a
# record selected by id or label routes the capture over fm-on.sh to that
# record's host-local capture verb (fm-remote-secondmate-control.sh or
# fm-remote-task-control.sh), clamped to the verb's 100-line cap. An
# unreachable host or unreadable endpoint fails loudly naming the host; the
# local backend adapters are never asked to read a remote target. A record
# whose placement is malformed is refused with the route library's reason, and
# a sandbox task's recorded window names no endpoint here, so an explicit
# target matching it is refused rather than read locally.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-route-lib.sh
. "$SCRIPT_DIR/fm-remote-route-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
N=${2:-40}

# Refuse a record whose placement is malformed; the remote path below owns the
# only remote reads this command performs.
peek_refuse_unroutable() {  # <meta>
  local meta=$1 id
  id=${meta##*/}
  id=${id%.meta}
  if ! fm_remote_route_resolve "$meta" "$id"; then
    echo "error: not reading $id: $FM_REMOTE_ROUTE_ERROR" >&2
    exit 1
  fi
}

REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ]; then
  peek_refuse_unroutable "$REMOTE_META"
fi
if [ -n "$REMOTE_META" ] && [ "$FM_REMOTE_ROUTE_KIND" != none ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$FM_REMOTE_ROUTE_HOST
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    "$FM_REMOTE_ROUTE_CONTROL" capture "$REMOTE_ID" "$N" < /dev/null; then
    if [ "$FM_REMOTE_ROUTE_KIND" = task ]; then
      echo "error: could not read the sandbox pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the task is not thereby dead)" >&2
    else
      echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    fi
    exit 1
  fi
  exit 0
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

# An explicit target that names a recorded window is checked the same way, so
# a sandbox task's window=remote:<id> is never captured as a local pane.
if [ -z "$REMOTE_META" ]; then
  WINDOW_META=$(fm_backend_meta_for_window "$T" "$STATE" 2>/dev/null || true)
  if [ -n "$WINDOW_META" ]; then
    peek_refuse_unroutable "$WINDOW_META"
    if [ "$FM_REMOTE_ROUTE_KIND" = task ]; then
      WINDOW_ID=${WINDOW_META##*/}
      WINDOW_ID=${WINDOW_ID%.meta}
      echo "error: not reading $T as a local pane: it is the recorded window of sandbox task $WINDOW_ID on $FM_REMOTE_ROUTE_HOST; peek the task by its id ($WINDOW_ID) instead" >&2
      exit 1
    fi
  fi
fi

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
