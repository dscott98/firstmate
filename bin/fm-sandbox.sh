#!/usr/bin/env bash
# fm-sandbox.sh - the provider-neutral SANDBOX ADAPTER: the only Firstmate code
# that invokes a sandbox provider. It translates Firstmate's per-task sandbox
# lifecycle onto one external provider command with argv only, never a shell
# string, and validates lifecycle records before they reach Firstmate
# (exec output is relayed verbatim). The provider owns the infrastructure (VMs, labels, the
# firewall, SSH wiring, reaping); Firstmate owns the lifecycle decisions.
# Firstmate never holds the provider's API token and never calls the
# provider's API: every effect and every observation flows through this
# script. docs/remote-sandboxes.md owns the operator guide; this header is
# the single owner of the provider command, output, and exit contracts.
#
# Usage: fm-sandbox.sh <verb> [args]
#   config
#   create <task-id> [--profile <name>] [--ttl <duration>]
#   status <name>
#   list
#   extend <name> [--ttl <duration>]
#   hold <name>
#   release <name>
#   policy <name>
#   exec <name> -- <argv...>
#   snapshot <name> <label>
#   rollback <name> <label>
#   destroy <name> --expect-task <task-id>
#
# DEFAULT-OFF AND CONFIGURATION (config/sandbox-provider, local and
# gitignored; FM_HOME selects the home, FM_CONFIG_OVERRIDE redirects
# config/). With no config file every verb except --help refuses with exit 3
# and changes nothing else. docs/configuration.md, "Sandbox provider",
# owns the file format, required and optional keys, and default-profile
# restrictions.
#
# config never invokes the provider: it validates the file and the provider
# command, then prints the settings a caller needs as key=value lines -
# provider (the provider command's file name, which must be a safe token),
# default_profile, ttl, remote_root, and remote_home (the sandbox template's
# Firstmate code root /opt/firstmate and one-task home /home/agent/fm-home). It is how
# bin/fm-spawn.sh reads this file without parsing it a second time.
#
# HOME TAG. Sandboxes are labelled fm_home=<tag> so two firstmate homes
# sharing one provider namespace have separate lifecycle scopes.
# The tag comes from fm_home_hometag (bin/fm-backend-hometag-lib.sh),
# derived from the resolved operational FM_HOME path.
#
# PROVIDER INVOCATION CONTRACT (argv only; every value below is one argv
# element and this script never builds a shell string):
#   <provider> create <task-id> --home <tag> --profile <name> --ttl <dur>
#   <provider> status <name>
#   <provider> list --home <tag>
#   <provider> extend <name> --ttl <dur>
#   <provider> hold <name>
#   <provider> release <name>
#   <provider> policy <name>
#   <provider> exec <name> -- <argv...>
#   <provider> snapshot <name> <label>
#   <provider> rollback <name> <label>
#   <provider> destroy <name> --expect-task <task-id> --home <tag>
# create must label the sandbox fm_task=<task-id> and fm_home=<tag> and set
# the hold label (which the provider's reaper always honours, in addition to
# the TTL). list must return only the calling home's records; this script
# filters the output again, fail-closed. destroy must refuse when the
# sandbox's fm_task or fm_home labels disagree with --expect-task or --home,
# and must treat an already-absent sandbox as success. exec is bootstrap
# only: its argv after -- is the command argv, relayed verbatim.
# Before extend, hold, release, policy, exec, snapshot, or rollback, this
# adapter reads and validates status and refuses absent sandboxes or a
# missing/mismatched fm_home label. No requested verb runs on refusal.
#
# PROVIDER OUTPUT CONTRACT (every verb except exec): stdout is key=value
# records, one record per line, with space-separated key=value fields,
# no blank lines, non-empty values containing no whitespace or "=", keys matched by
# ^[a-z][a-z0-9_]*$. Keys come from one closed set, split per verb:
#   create:  name vmid node ssh_alias user profile ttl_expires hostkey
#            (all eight required; hostkey must be exactly "pinned")
#   object:  name vmid node ssh_alias user profile ttl_expires state
#            fm_task fm_home hold
#            (status, list, extend, hold, release, snapshot, rollback,
#            destroy; status requires state=running|stopped|absent, with
#            fm_task and fm_home required for running/stopped)
#   policy:  name profile rule
#            (policy requires profile; rule fields may repeat)
# A key outside the set for that verb, a duplicate key within one record, a
# malformed field, an empty value, or a missing required key is refused and
# nothing from that call is trusted. create/status return exactly one record.
# list is one record per sandbox; every record must carry name and state, and this
# script keeps only records whose fm_home equals the home tag (a record
# without the label is dropped, not refused). Retained running/stopped
# list records require fm_task and fm_home; absent records need no labels.
# extend, hold, release,
# snapshot, rollback, and destroy may answer with empty output. exec is
# exempt from the key=value contract: the provider relays the remote
# command's stdout and exit status verbatim and this script passes both
# through untouched, including non-zero statuses.
#
# EXIT STATUSES (these also apply to the ownership status check before
# exec; once that check succeeds, exec relays the provider status unchanged):
#   0  success (config/create/status/list/policy print validated key=value
#      lines)
#   2  usage error: unknown verb, missing or malformed arguments, or a
#      name, task id, label, or profile that is not a safe single token
#      (non-empty, printable, no whitespace, no "=", no leading "-")
#   3  refusal: no config/sandbox-provider (default-off), a malformed
#      config, a provider command that is missing or not executable, a
#      provider exit that is neither 0 nor 75 (its stderr is included), or
#      provider output that violates the contract above, or an ownership
#      status check that finds an absent or foreign-home sandbox
#   4  capacity blocker: the provider exited 75, its dedicated capacity
#      refusal status. A capacity refusal is a blocker to surface, never a
#      reason to fall back to local placement or to retry silently.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/sandbox-provider"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"

FM_SANDBOX_CAPACITY_RC=75

FM_SANDBOX_PROVIDER=
FM_SANDBOX_DEFAULT_PROFILE=
FM_SANDBOX_TTL=
FM_SANDBOX_REMOTE_ROOT=/opt/firstmate
FM_SANDBOX_REMOTE_HOME=/home/agent/fm-home
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  FM_SANDBOX_REMOTE_ROOT=${FM_TEST_SANDBOX_ROOT:-$FM_SANDBOX_REMOTE_ROOT}
  FM_SANDBOX_REMOTE_HOME=${FM_TEST_SANDBOX_HOME:-$FM_SANDBOX_REMOTE_HOME}
fi
FM_SANDBOX_OUT=
FM_SANDBOX_RC=0

usage() {
  cat <<'USAGE'
usage: fm-sandbox.sh <verb> [args]
  config
  create <task-id> [--profile <name>] [--ttl <duration>]
  status <name>
  list
  extend <name> [--ttl <duration>]
  hold <name>
  release <name>
  policy <name>
  exec <name> -- <argv...>
  snapshot <name> <label>
  rollback <name> <label>
  destroy <name> --expect-task <task-id>
This script is the only Firstmate code that invokes the sandbox provider.
Its header owns the provider command, output, and exit contracts.
USAGE
}

fm_usage_error() {
  printf 'usage error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

refuse() {
  printf 'refused: %s\n' "$1" >&2
  exit 3
}

blocked() {
  printf 'blocked: %s\n' "$1" >&2
  exit 4
}

fm_sandbox_token_ok() {
  case "$1" in
    ''|-*|*[[:space:]]*|*=*|*[![:print:]]*) return 1 ;;
  esac
  return 0
}

fm_sandbox_valid_duration() {
  [[ "$1" =~ ^[0-9]+[smhdw]$ ]]
}

fm_sandbox_read_config() {
  [ -f "$CONFIG" ] || refuse "no sandbox provider configured at $CONFIG; sandbox placement is default-off and every sandbox request refuses until an operator writes config/sandbox-provider (docs/remote-sandboxes.md)"
  local line key value got_path=0 seen=" " cr=$'\r'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$cr"}
    if [ "$got_path" -eq 0 ]; then
      case "$line" in
        /*) ;;
        *) refuse "the first line of $CONFIG must be the provider command's absolute path (found '${line:-<empty>}')" ;;
      esac
      FM_SANDBOX_PROVIDER=$line
      got_path=1
      continue
    fi
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) refuse "malformed line '$line' in $CONFIG: expected key=value" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$seen" in
      *" $key "*) refuse "duplicate key '$key' in $CONFIG" ;;
    esac
    case "$key" in
      default_profile)
        fm_sandbox_token_ok "$value" || refuse "default_profile '$value' in $CONFIG must be a non-empty printable token without whitespace, '=', or a leading '-'"
        [ "$value" != open ] || refuse "default_profile=open is forbidden: open requires explicit per-task --profile open"
        FM_SANDBOX_DEFAULT_PROFILE=$value
        ;;
      ttl)
        fm_sandbox_valid_duration "$value" || refuse "ttl '$value' in $CONFIG must be one integer plus one unit of s, m, h, d, or w, for example 4h"
        FM_SANDBOX_TTL=$value
        ;;
      ssh_include)
        case "$value" in
          /*) ;;
          *) refuse "$key '$value' in $CONFIG must be an absolute path" ;;
        esac
        case "$value" in
          *[[:space:]]*|*[[:cntrl:]]*) refuse "$key '$value' in $CONFIG must not contain whitespace or control characters" ;;
        esac
        ;;
      *)
        refuse "unknown key '$key' in $CONFIG: accepted keys are default_profile, ttl, and ssh_include"
        ;;
    esac
    seen="$seen$key "
  done < "$CONFIG"
  [ "$got_path" -eq 1 ] || refuse "$CONFIG is empty; its first line must be the provider command's absolute path"
  local k
  for k in default_profile ttl ssh_include; do
    case "$seen" in
      *" $k "*) ;;
      *) refuse "missing key '$k' in $CONFIG" ;;
    esac
  done
}

fm_sandbox_require_provider() {
  [ -f "$FM_SANDBOX_PROVIDER" ] || refuse "sandbox provider command '$FM_SANDBOX_PROVIDER' from $CONFIG does not exist"
  [ -x "$FM_SANDBOX_PROVIDER" ] || refuse "sandbox provider command '$FM_SANDBOX_PROVIDER' from $CONFIG is not executable"
}

fm_sandbox_invoke() {
  fm_sandbox_require_provider
  local err_file detail
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-sandbox.XXXXXX") || refuse "cannot create a temp file for the provider's stderr"
  if FM_SANDBOX_OUT=$(
    "$FM_SANDBOX_PROVIDER" "$@" 2>"$err_file"
    rc=$?
    printf '.'
    exit "$rc"
  ); then
    FM_SANDBOX_RC=0
  else
    FM_SANDBOX_RC=$?
  fi
  FM_SANDBOX_OUT=${FM_SANDBOX_OUT%.}
  FM_SANDBOX_OUT=${FM_SANDBOX_OUT%$'\n'}
  if [ "$FM_SANDBOX_RC" -eq "$FM_SANDBOX_CAPACITY_RC" ]; then
    rm -f "$err_file"
    blocked "the sandbox provider reports no capacity for this request (provider exit $FM_SANDBOX_CAPACITY_RC); this is a blocker to surface, never a reason to fall back to local placement"
  fi
  if [ "$FM_SANDBOX_RC" -ne 0 ]; then
    detail=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    if [ -n "$detail" ]; then
      refuse "sandbox provider exited $FM_SANDBOX_RC: $detail"
    fi
    refuse "sandbox provider exited $FM_SANDBOX_RC with no stderr"
  fi
  # On success the provider's stderr is diagnostics, not data: forward it.
  cat "$err_file" >&2 2>/dev/null || true
  rm -f "$err_file"
  return 0
}

fm_sandbox_key_in_create_set() {
  case "$1" in
    name|vmid|node|ssh_alias|user|profile|ttl_expires|hostkey) return 0 ;;
    *) return 1 ;;
  esac
}

fm_sandbox_key_in_object_set() {
  case "$1" in
    name|vmid|node|ssh_alias|user|profile|ttl_expires|state|fm_task|fm_home|hold) return 0 ;;
    *) return 1 ;;
  esac
}

fm_sandbox_key_in_policy_set() {
  case "$1" in
    name|profile|rule) return 0 ;;
    *) return 1 ;;
  esac
}

FM_SANDBOX_LINE_KEY=
FM_SANDBOX_LINE_VALUE=

fm_sandbox_parse_field() {
  local line=$1 cr=$'\r'
  case "$line" in
    *"$cr"*) refuse "malformed provider output (carriage return): '$line'" ;;
  esac
  case "$line" in
    *=*) ;;
    *) refuse "malformed provider output (expected key=value): '$line'" ;;
  esac
  FM_SANDBOX_LINE_KEY=${line%%=*}
  FM_SANDBOX_LINE_VALUE=${line#*=}
  [[ "$FM_SANDBOX_LINE_KEY" =~ ^[a-z][a-z0-9_]*$ ]] || refuse "malformed provider output key: '$FM_SANDBOX_LINE_KEY'"
  case "$FM_SANDBOX_LINE_VALUE" in
    ''|*=*|*[[:space:]]*) refuse "malformed provider output value for '$FM_SANDBOX_LINE_KEY': expected a non-empty value without whitespace or '='" ;;
  esac
}

fm_sandbox_check_semantics() {
  case "$1" in
    state)
      case "$2" in
        running|stopped|absent) ;;
        *) refuse "provider output state must be running, stopped, or absent (got '$2')" ;;
      esac
      ;;
    hostkey)
      [ "$2" = pinned ] || refuse "provider output hostkey must be 'pinned' (got '$2'); firstmate will not trust a sandbox host key the provider did not pin"
      ;;
  esac
}

FM_SANDBOX_RECORD_HOME=
FM_SANDBOX_RECORD_STATE=

fm_sandbox_validate_record() {
  local keyset=$1 required=$2 verb=$3 line=$4 tag=${5:-} field key state='' seen=" "
  local -a fields=()
  FM_SANDBOX_RECORD_HOME=
  FM_SANDBOX_RECORD_STATE=
  IFS=' ' read -r -a fields <<<"$line"
  [ "${#fields[@]}" -gt 0 ] || refuse "empty provider record for $verb"
  for field in "${fields[@]}"; do
    fm_sandbox_parse_field "$field"
    key=$FM_SANDBOX_LINE_KEY
    "fm_sandbox_key_in_${keyset}_set" "$key" || refuse "unknown provider output key '$key' for $verb"
    fm_sandbox_check_semantics "$key" "$FM_SANDBOX_LINE_VALUE"
    if [ "$key" != rule ]; then
      case "$seen" in
        *" $key "*) refuse "duplicate provider output key '$key' for $verb" ;;
      esac
    fi
    seen="$seen$key "
    case "$key" in
      fm_home) FM_SANDBOX_RECORD_HOME=$FM_SANDBOX_LINE_VALUE ;;
      state) state=$FM_SANDBOX_LINE_VALUE; FM_SANDBOX_RECORD_STATE=$state ;;
    esac
  done
  if [ "$state" = running ] || [ "$state" = stopped ]; then
    if [ "$verb" = status ] || { [ "$verb" = list ] && [ "$FM_SANDBOX_RECORD_HOME" = "$tag" ]; }; then
      required="$required fm_task fm_home"
    fi
  fi
  for key in $required; do
    case "$seen" in
      *" $key "*) ;;
      *) refuse "provider output for $verb is missing required key '$key'" ;;
    esac
  done
}

fm_sandbox_emit_single() {
  local keyset=$1 required=$2 verb=$3
  if [ -z "$FM_SANDBOX_OUT" ] && [ -z "$required" ]; then
    return 0
  fi
  case "$FM_SANDBOX_OUT" in
    *$'\n'*) refuse "provider output for $verb must contain exactly one record line" ;;
  esac
  fm_sandbox_validate_record "$keyset" "$required" "$verb" "$FM_SANDBOX_OUT"
  printf '%s\n' "$FM_SANDBOX_OUT"
}

fm_sandbox_require_owned() {
  fm_sandbox_invoke status "$NAME"
  fm_sandbox_emit_single object state status >/dev/null
  [ "$FM_SANDBOX_RECORD_STATE" != absent ] || refuse "$VERB requires an existing sandbox: '$NAME' is absent"
  [ "$FM_SANDBOX_RECORD_HOME" = "$TAG" ] || refuse "$VERB refused for '$NAME': fm_home label mismatch (expected '$TAG', got '$FM_SANDBOX_RECORD_HOME')"
}

fm_sandbox_emit_list() {
  local tag=$1 line
  local -a records=()
  if [ -n "$FM_SANDBOX_OUT" ]; then
    while IFS= read -r line; do
      fm_sandbox_validate_record object "name state" list "$line" "$tag"
      if [ "$FM_SANDBOX_RECORD_HOME" = "$tag" ]; then
        records+=("$line")
      fi
    done <<<"$FM_SANDBOX_OUT"
  fi
  if [ "${#records[@]}" -gt 0 ]; then
    printf '%s\n' "${records[@]}"
  fi
  return 0
}

# --- argument parsing --------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

VERB=${1:-}
[ -n "$VERB" ] || fm_usage_error "a verb is required"
shift

TASK_ID=
NAME=
LABEL=
PROFILE_FLAG=
TTL_FLAG=
EXPECT_TASK=
EXEC_ARGV=()

case "$VERB" in
  config)
    [ "$#" -eq 0 ] || fm_usage_error "config takes no arguments"
    ;;
  create)
    TASK_ID=${1:-}
    [ -n "$TASK_ID" ] || fm_usage_error "create requires a task id"
    fm_sandbox_token_ok "$TASK_ID" || fm_usage_error "task id '$TASK_ID' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --profile)
          [ "$#" -ge 2 ] || fm_usage_error "--profile requires a value"
          PROFILE_FLAG=$2
          shift 2
          ;;
        --ttl)
          [ "$#" -ge 2 ] || fm_usage_error "--ttl requires a value"
          TTL_FLAG=$2
          shift 2
          ;;
        *)
          fm_usage_error "unknown argument '$1' for create"
          ;;
      esac
    done
    if [ -n "$PROFILE_FLAG" ]; then
      fm_sandbox_token_ok "$PROFILE_FLAG" || fm_usage_error "profile '$PROFILE_FLAG' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    fi
    if [ -n "$TTL_FLAG" ]; then
      fm_sandbox_valid_duration "$TTL_FLAG" || fm_usage_error "--ttl '$TTL_FLAG' must be one integer plus one unit of s, m, h, d, or w, for example 4h"
    fi
    ;;
  status|hold|release|policy)
    NAME=${1:-}
    [ -n "$NAME" ] || fm_usage_error "$VERB requires a sandbox name"
    fm_sandbox_token_ok "$NAME" || fm_usage_error "sandbox name '$NAME' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    [ "$#" -eq 0 ] || fm_usage_error "$VERB takes no arguments beyond the sandbox name"
    ;;
  list)
    [ "$#" -eq 0 ] || fm_usage_error "list takes no arguments"
    ;;
  extend)
    NAME=${1:-}
    [ -n "$NAME" ] || fm_usage_error "extend requires a sandbox name"
    fm_sandbox_token_ok "$NAME" || fm_usage_error "sandbox name '$NAME' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ttl)
          [ "$#" -ge 2 ] || fm_usage_error "--ttl requires a value"
          TTL_FLAG=$2
          shift 2
          ;;
        *)
          fm_usage_error "unknown argument '$1' for extend"
          ;;
      esac
    done
    if [ -n "$TTL_FLAG" ]; then
      fm_sandbox_valid_duration "$TTL_FLAG" || fm_usage_error "--ttl '$TTL_FLAG' must be one integer plus one unit of s, m, h, d, or w, for example 4h"
    fi
    ;;
  exec)
    NAME=${1:-}
    [ -n "$NAME" ] || fm_usage_error "exec requires a sandbox name"
    fm_sandbox_token_ok "$NAME" || fm_usage_error "sandbox name '$NAME' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    [ "${1:-}" = "--" ] || fm_usage_error "exec requires '--' before the command argv, because the command is an argv, never a shell string"
    shift
    [ "$#" -ge 1 ] || fm_usage_error "exec requires at least one command argument after '--'"
    EXEC_ARGV=("$@")
    ;;
  snapshot|rollback)
    NAME=${1:-}
    [ -n "$NAME" ] || fm_usage_error "$VERB requires a sandbox name"
    fm_sandbox_token_ok "$NAME" || fm_usage_error "sandbox name '$NAME' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    LABEL=${1:-}
    [ -n "$LABEL" ] || fm_usage_error "$VERB requires a label"
    fm_sandbox_token_ok "$LABEL" || fm_usage_error "label '$LABEL' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    [ "$#" -eq 0 ] || fm_usage_error "$VERB takes no arguments beyond the sandbox name and label"
    ;;
  destroy)
    NAME=${1:-}
    [ -n "$NAME" ] || fm_usage_error "destroy requires a sandbox name"
    fm_sandbox_token_ok "$NAME" || fm_usage_error "sandbox name '$NAME' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expect-task)
          [ "$#" -ge 2 ] || fm_usage_error "--expect-task requires a value"
          EXPECT_TASK=$2
          shift 2
          ;;
        *)
          fm_usage_error "unknown argument '$1' for destroy"
          ;;
      esac
    done
    [ -n "$EXPECT_TASK" ] || fm_usage_error "destroy requires --expect-task <task-id>, so it refuses when the sandbox's labels disagree"
    fm_sandbox_token_ok "$EXPECT_TASK" || fm_usage_error "task id '$EXPECT_TASK' must be a non-empty printable token without whitespace, '=', or a leading '-'"
    ;;
  *)
    fm_usage_error "unknown verb '$VERB'"
    ;;
esac

# --- config, home tag, dispatch ----------------------------------------------

fm_sandbox_read_config
TAG=$(fm_home_hometag) || refuse "cannot resolve operational home '$FM_HOME'"

case "$VERB" in
  extend|hold|release|policy|exec|snapshot|rollback) fm_sandbox_require_owned ;;
esac

case "$VERB" in
  config)
    fm_sandbox_require_provider
    PROVIDER_NAME=${FM_SANDBOX_PROVIDER##*/}
    fm_sandbox_token_ok "$PROVIDER_NAME" \
      || refuse "the provider command's file name '$PROVIDER_NAME' from $CONFIG must be a printable token without whitespace, '=', or a leading '-', because task records name the provider by it"
    printf 'provider=%s\n' "$PROVIDER_NAME"
    printf 'default_profile=%s\n' "$FM_SANDBOX_DEFAULT_PROFILE"
    printf 'ttl=%s\n' "$FM_SANDBOX_TTL"
    printf 'remote_root=%s\n' "$FM_SANDBOX_REMOTE_ROOT"
    printf 'remote_home=%s\n' "$FM_SANDBOX_REMOTE_HOME"
    ;;
  create)
    PROFILE=${PROFILE_FLAG:-$FM_SANDBOX_DEFAULT_PROFILE}
    TTL=${TTL_FLAG:-$FM_SANDBOX_TTL}
    fm_sandbox_invoke create "$TASK_ID" --home "$TAG" --profile "$PROFILE" --ttl "$TTL"
    fm_sandbox_emit_single create "name vmid node ssh_alias user profile ttl_expires hostkey" create
    ;;
  status)
    fm_sandbox_invoke status "$NAME"
    fm_sandbox_emit_single object state status
    ;;
  list)
    fm_sandbox_invoke list --home "$TAG"
    fm_sandbox_emit_list "$TAG"
    ;;
  extend)
    TTL=${TTL_FLAG:-$FM_SANDBOX_TTL}
    fm_sandbox_invoke extend "$NAME" --ttl "$TTL"
    fm_sandbox_emit_single object "" extend
    ;;
  hold|release)
    fm_sandbox_invoke "$VERB" "$NAME"
    fm_sandbox_emit_single object "" "$VERB"
    ;;
  policy)
    fm_sandbox_invoke policy "$NAME"
    fm_sandbox_emit_single policy profile policy
    ;;
  snapshot|rollback)
    fm_sandbox_invoke "$VERB" "$NAME" "$LABEL"
    fm_sandbox_emit_single object "" "$VERB"
    ;;
  destroy)
    fm_sandbox_invoke destroy "$NAME" --expect-task "$EXPECT_TASK" --home "$TAG"
    fm_sandbox_emit_single object "" destroy
    ;;
  exec)
    fm_sandbox_require_provider
    # Raw relay: the provider relays the remote command's stdout and exit
    # status verbatim, so nothing here validates or translates them.
    set +e
    "$FM_SANDBOX_PROVIDER" exec "$NAME" -- "${EXEC_ARGV[@]}"
    EXEC_RC=$?
    set -e
    exit "$EXEC_RC"
    ;;
esac
