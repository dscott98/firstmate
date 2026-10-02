#!/usr/bin/env bash
# shellcheck disable=SC2034 # Route fields are output globals for sourcing callers.
# fm-remote-route-lib.sh - the single owner of remote dispatch. For one task
# record in this home it answers whether the record is remotely placed, which
# kind of remote placement it is, which host-side control script serves it,
# and which route reaches it. Every consumer that branches on remote placement
# asks here instead of keying on remote_host alone, so a sandbox task record
# can never fall into secondmate-only code and is never read as a local
# endpoint.
#
# Source this file and call:
#   fm_remote_route_resolve <meta-file> [<task-id>]
# <task-id> defaults to the record's basename without .meta. An empty path or
# an absent record resolves to none. On status 0, FM_REMOTE_ROUTE_KIND is one
# of:
#   none        not remotely placed; the caller keeps its local path
#   secondmate  a remote secondmate (the legacy form below)
#   task        a sandbox task (the strict form below)
# For secondmate and task, FM_REMOTE_ROUTE_HOST, FM_REMOTE_ROUTE_ROOT, and
# FM_REMOTE_ROUTE_HOME name the SSH alias, remote code root, and remote
# FM_HOME, and FM_REMOTE_ROUTE_CONTROL names the tracked host-side control
# script that serves the record. A record whose placement fields are
# malformed or contradictory returns 1 with FM_REMOTE_ROUTE_KIND=invalid and
# FM_REMOTE_ROUTE_ERROR naming the defect; a caller refuses it, because such a
# record is neither local nor a secondmate.
#
# Placement is explicit and never inferred.
# - Legacy form: a record with no placement= and no remote_kind= line keeps
#   the original signal, read exactly as every consumer read it before. A
#   non-empty remote_host= marks a remote secondmate, which only kind=secondmate
#   may carry; bin/fm-spawn.sh records its remote code root as remote_root= and
#   its remote home as home=. A record without remote_host= is local.
# - Strict form: a record that carries placement= or remote_kind= at all must
#   record placement= exactly once, as local or sandbox. placement=local carries
#   no remote route. placement=sandbox is a sandbox task, valid only with
#   exactly one each of kind=ship or kind=scout, remote_kind=task,
#   window=remote:<id>, endpoint_task_id=<id>, remote_host=, remote_root=, and
#   remote_home=. Its route must pass fm_remote_route_check_shape, and its code
#   root and home must pass fm_remote_route_check_disjoint. A registry route is
#   held to that same disjointness when bin/fm-secondmate-registry-lib.sh
#   validates data/secondmates.md; a task record has no write-time validator in
#   this home, so the read-time check here carries it. The record's other sandbox
#   fields (remote_backend, remote_target, worktree - a path on the VM that is
#   never probed locally - sandbox_provider, sandbox_name, and sandbox_profile)
#   are not routing inputs and stay with the consumers that need them.
#
# A consumer that cannot yet serve a verb for a sandbox task refuses it with
# fm_remote_route_unsupported <task-id> <action>, the one wording for that
# refusal, instead of treating the record as local or as a remote secondmate.
#
# fm_remote_route_check_shape <host> <root> <home> owns the transport shape
# every remote route passes before bin/fm-on.sh encodes it: a safe SSH alias,
# and an absolute root and home with no control characters, traversal
# components, or empty path components. fm_remote_route_check_path_shape
# <root> <home> is its path half and fm_remote_route_check_disjoint <root>
# <home> the overlap rule a task route adds, so bin/fm-brief.sh --for-home and
# --for-root render a brief only for a root and home a task record could
# route to. Each returns 1 with FM_REMOTE_ROUTE_ERROR set.

FM_REMOTE_ROUTE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-backend.sh
. "$FM_REMOTE_ROUTE_LIB_DIR/fm-backend.sh"

FM_REMOTE_ROUTE_KIND=none
FM_REMOTE_ROUTE_HOST=
FM_REMOTE_ROUTE_ROOT=
FM_REMOTE_ROUTE_HOME=
FM_REMOTE_ROUTE_CONTROL=
FM_REMOTE_ROUTE_ERROR=

fm_remote_route_reset() {
  FM_REMOTE_ROUTE_KIND=none
  FM_REMOTE_ROUTE_HOST=
  FM_REMOTE_ROUTE_ROOT=
  FM_REMOTE_ROUTE_HOME=
  FM_REMOTE_ROUTE_CONTROL=
  FM_REMOTE_ROUTE_ERROR=
}

fm_remote_route_invalid() { # <reason>
  fm_remote_route_reset
  FM_REMOTE_ROUTE_KIND=invalid
  FM_REMOTE_ROUTE_ERROR=$1
  return 1
}

fm_remote_route_check_shape() { # <host> <root> <home>
  local host=$1
  FM_REMOTE_ROUTE_ERROR=
  case "$host" in ''|-*|*[!A-Za-z0-9._-]*)
    FM_REMOTE_ROUTE_ERROR="configured SSH alias is unsafe: $host"
    return 1
    ;;
  esac
  fm_remote_route_check_path_shape "$2" "$3"
}

fm_remote_route_check_path_shape() { # <root> <home>
  local root=$1 home=$2 path
  FM_REMOTE_ROUTE_ERROR=
  case "$root" in /*) ;; *)
    FM_REMOTE_ROUTE_ERROR="configured remote root is not absolute: $root"
    return 1
    ;;
  esac
  case "$home" in /*) ;; *)
    FM_REMOTE_ROUTE_ERROR="configured remote home is not absolute: $home"
    return 1
    ;;
  esac
  case "$root$home" in *$'\n'*|*$'\r'*|*$'\t'*)
    FM_REMOTE_ROUTE_ERROR="configured remote root or home contains control characters"
    return 1
    ;;
  esac
  for path in "$root" "$home"; do
    case "/$path/" in */../*|*/./*)
      FM_REMOTE_ROUTE_ERROR="configured remote root or home contains traversal components"
      return 1
      ;;
    esac
    case "$path" in *'//'*)
      FM_REMOTE_ROUTE_ERROR="configured remote root or home contains an empty path component"
      return 1
      ;;
    esac
  done
  return 0
}

fm_remote_route_check_disjoint() { # <root> <home>
  local root=$1 home=$2 root_normalized home_normalized
  FM_REMOTE_ROUTE_ERROR=
  root_normalized=${root%/}
  home_normalized=${home%/}
  if [ -z "$root_normalized" ] || [ -z "$home_normalized" ] || [ "$root_normalized" = "$home_normalized" ]; then
    FM_REMOTE_ROUTE_ERROR="an overlapping remote root and home: $root"
    return 1
  fi
  case "$home_normalized/" in "$root_normalized/"*)
    FM_REMOTE_ROUTE_ERROR="its remote home inside its code root: $home"
    return 1
    ;;
  esac
  case "$root_normalized/" in "$home_normalized/"*)
    FM_REMOTE_ROUTE_ERROR="its remote code root inside its home: $root"
    return 1
    ;;
  esac
  return 0
}

fm_remote_route_resolve() { # <meta-file> [<task-id>]
  local meta=${1:-} id=${2:-} placement_lines remote_kind_lines placement
  local kind remote_kind window binding host root home
  fm_remote_route_reset
  [ -n "$meta" ] && [ -f "$meta" ] || return 0
  if [ -z "$id" ]; then
    id=${meta##*/}
    id=${id%.meta}
  fi
  placement_lines=$(LC_ALL=C grep -c '^placement=' "$meta" 2>/dev/null || true)
  remote_kind_lines=$(LC_ALL=C grep -c '^remote_kind=' "$meta" 2>/dev/null || true)
  case "$placement_lines:$remote_kind_lines" in
    0:0|:|0:|:0)
      host=$(fm_meta_get "$meta" remote_host)
      [ -n "$host" ] || return 0
      kind=$(fm_meta_get "$meta" kind)
      if [ "$kind" != secondmate ]; then
        fm_remote_route_invalid "task $id records remote_host=$host without placement=sandbox, and that remote placement is valid only for a secondmate"
        return 1
      fi
      FM_REMOTE_ROUTE_KIND=secondmate
      FM_REMOTE_ROUTE_HOST=$host
      FM_REMOTE_ROUTE_ROOT=$(fm_meta_get "$meta" remote_root)
      FM_REMOTE_ROUTE_HOME=$(fm_meta_get "$meta" home)
      FM_REMOTE_ROUTE_CONTROL=fm-remote-secondmate-control.sh
      return 0
      ;;
  esac
  if ! placement=$(fm_backend_meta_exact_value "$meta" placement); then
    fm_remote_route_invalid "task $id must record placement= exactly once, as local or sandbox"
    return 1
  fi
  case "$placement" in
    local)
      if [ "$remote_kind_lines" != 0 ] || [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
        fm_remote_route_invalid "task $id records placement=local together with a remote route"
        return 1
      fi
      return 0
      ;;
    sandbox) ;;
    *)
      fm_remote_route_invalid "task $id records an unknown placement '$placement' (expected local or sandbox)"
      return 1
      ;;
  esac
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    fm_remote_route_invalid "sandbox task record $meta does not name a valid task id"
    return 1
    ;;
  esac
  kind=$(fm_backend_meta_exact_value "$meta" kind) || kind=
  case "$kind" in
    ship|scout) ;;
    *)
      fm_remote_route_invalid "task $id records placement=sandbox, which is valid only for one kind=ship or kind=scout record (found kind '${kind:-missing or repeated}')"
      return 1
      ;;
  esac
  remote_kind=$(fm_backend_meta_exact_value "$meta" remote_kind) || remote_kind=
  if [ "$remote_kind" != task ]; then
    fm_remote_route_invalid "sandbox task $id must record remote_kind=task exactly once"
    return 1
  fi
  window=$(fm_backend_meta_exact_value "$meta" window) || window=
  if [ "$window" != "remote:$id" ]; then
    fm_remote_route_invalid "sandbox task $id must record window=remote:$id exactly once"
    return 1
  fi
  binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || binding=
  if [ "$binding" != "$id" ]; then
    fm_remote_route_invalid "sandbox task $id must record endpoint_task_id=$id exactly once"
    return 1
  fi
  host=$(fm_backend_meta_exact_value "$meta" remote_host) || host=
  root=$(fm_backend_meta_exact_value "$meta" remote_root) || root=
  home=$(fm_backend_meta_exact_value "$meta" remote_home) || home=
  if [ -z "$host" ] || [ -z "$root" ] || [ -z "$home" ]; then
    fm_remote_route_invalid "sandbox task $id must record remote_host=, remote_root=, and remote_home= exactly once each"
    return 1
  fi
  if ! fm_remote_route_check_shape "$host" "$root" "$home"; then
    fm_remote_route_invalid "sandbox task $id has an unsafe route: $FM_REMOTE_ROUTE_ERROR"
    return 1
  fi
  if ! fm_remote_route_check_disjoint "$root" "$home"; then
    fm_remote_route_invalid "sandbox task $id has $FM_REMOTE_ROUTE_ERROR"
    return 1
  fi
  FM_REMOTE_ROUTE_KIND=task
  FM_REMOTE_ROUTE_HOST=$host
  FM_REMOTE_ROUTE_ROOT=$root
  FM_REMOTE_ROUTE_HOME=$home
  FM_REMOTE_ROUTE_CONTROL=fm-remote-task-control.sh
  return 0
}

fm_remote_route_unsupported() { # <task-id> <action>
  printf 'task %s runs in a sandbox on %s; %s is not supported for a sandbox task in this Firstmate version, so it was refused rather than treated as local or as a remote secondmate' \
    "$1" "${FM_REMOTE_ROUTE_HOST:-its remote host}" "$2"
}
