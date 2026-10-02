#!/usr/bin/env bash
# Execute one tracked Firstmate command in a configured remote home: a remote
# secondmate's home, or a sandbox task's one-task home.
#
# Usage:
#   fm-on.sh [--stdin] <secondmate-id|unambiguous-ssh-alias|sandbox-task-id> <fm-command> [args...]
#
# A secondmate route comes from a remote record in data/secondmates.md, which
# names an SSH config alias, remote Firstmate code root, and remote FM_HOME. A
# host alias may be used directly only when exactly one record selects it; an
# ambiguous alias is refused. A sandbox task route comes from this home's own
# task record instead, selected by its exact task id: when state/<id>.meta
# records a placement, bin/fm-remote-route-lib.sh resolves and validates it, and
# only placement=sandbox with remote_kind=task yields a route. A task id that
# also selects a registry record is refused as ambiguous. A record without
# placement= leaves registry routing exactly as it was. Every route passes the
# same transport shape checks before encoding. The command must be a genuine
# executable in this checkout's bin/fm-*.sh namespace. No per-command table
# exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# fm-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. FM_SSH_ALIVE_INTERVAL and FM_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
set -euo pipefail

if [ -n "${FM_ON_LOCAL_STATUS:-}" ]; then
  trap 'printf "local\n" > "$FM_ON_LOCAL_STATUS"' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
PROTOCOL=1

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-remote-route-lib.sh
. "$SCRIPT_DIR/fm-remote-route-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
if [ "${1:-}" = --stdin ]; then
  STDIN_MODE=caller
  shift
fi
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe secondmate id, sandbox task id, or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  fm-*.sh) ;;
  *) die "remote command must be a basename in the fm-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$FM_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Firstmate checkout: $COMMAND"
git -C "$FM_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Firstmate checkout: $COMMAND"

# Only a task record that records a placement is consulted, so a home without
# sandbox records routes exactly as the registry alone always did.
TASK_ROUTE=0
TASK_META="$STATE/$ROUTE.meta"
if [ -f "$TASK_META" ] && [ ! -L "$TASK_META" ] && LC_ALL=C grep -q '^placement=' "$TASK_META" 2>/dev/null; then
  fm_remote_route_resolve "$TASK_META" "$ROUTE" || die "$FM_REMOTE_ROUTE_ERROR"
  [ "$FM_REMOTE_ROUTE_KIND" != task ] || TASK_ROUTE=1
fi
# A task route needs no registry, but one that exists must still parse, so an
# id that also names a registry route is refused rather than guessed between.
if [ "$TASK_ROUTE" -eq 0 ] || [ -e "$REG" ] || [ -L "$REG" ]; then
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"
fi

MATCHES=0
HOST=
ROOT=
HOME_PATH=
if [ -f "$REG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    if [ "$SECONDMATE_REGISTRY_ID" = "$ROUTE" ] || [ "$SECONDMATE_REGISTRY_HOST" = "$ROUTE" ]; then
      MATCHES=$((MATCHES + 1))
      HOST=$SECONDMATE_REGISTRY_HOST
      ROOT=$SECONDMATE_REGISTRY_ROOT
      HOME_PATH=$SECONDMATE_REGISTRY_HOME
    fi
  done < "$REG"
fi
if [ "$TASK_ROUTE" -eq 1 ]; then
  [ "$MATCHES" -eq 0 ] \
    || die "remote route '$ROUTE' names a sandbox task and also selects $MATCHES configured secondmate route(s); refusing the ambiguous route"
  HOST=$FM_REMOTE_ROUTE_HOST
  ROOT=$FM_REMOTE_ROUTE_ROOT
  HOME_PATH=$FM_REMOTE_ROUTE_HOME
else
  [ "$MATCHES" -gt 0 ] || die "no remote secondmate or SSH alias matches '$ROUTE'"
  [ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured secondmates; use a secondmate id"
fi
fm_remote_route_check_shape "$HOST" "$ROOT" "$HOME_PATH" || die "$FM_REMOTE_ROUTE_ERROR"

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${FM_SSH_BIN:-ssh}
ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" fm-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
[ -z "${FM_ON_LOCAL_STATUS:-}" ] || printf 'remote\n' > "$FM_ON_LOCAL_STATUS"
shopt -s execfail
if [ "$STDIN_MODE" = caller ]; then
  exec "$SSH_BIN" "${SSH_ARGS[@]}"
fi
exec "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null
