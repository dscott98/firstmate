# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies.
# It also owns reading which status file a brief's status-append command names
# (fm_brief_status_append_paths) and the check that a ship or scout brief names
# only the status file of the home about to run it
# (fm_brief_foreign_status_file), which bin/fm-spawn.sh and the sandbox task
# control plane (bin/fm-remote-task-control.sh) both apply.

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" body <<<"$task"
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" present >/dev/null <<<"$task"
}

# Print the status file each status-append command in <file> names, one per
# line in file order. bin/fm-brief.sh renders that command as
#   echo "{state} [at=<epoch>]: {one short line}" >> '<state>/<id>.status' && ...
# and older scaffolds wrote it without the stamp and with the path unquoted, so
# a command is one whose `echo "{state}` appends with `" >> `, and its path is
# the single shell word that follows: single-quoted segments joined by `\'`, as
# the scaffold quotes it, or a bare word ending at whitespace or a backquote.
# Returns 1 when such a command's path cannot be read.
fm_brief_status_append_paths() {  # <file>
  local file=$1 line rest path
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *'echo "{state}'*'" >> '*) ;; *) continue ;; esac
    rest=${line#*'echo "{state}'}
    rest=${rest#*'" >> '}
    path=
    while [ -n "$rest" ]; do
      case "$rest" in
        "'"*)
          rest=${rest#\'}
          case "$rest" in *"'"*) ;; *) return 1 ;; esac
          path+=${rest%%\'*}
          rest=${rest#*\'}
          ;;
        "\\'"*)
          path+="'"
          rest=${rest#??}
          ;;
        [[:space:]]*|'`'*) break ;;
        *)
          path+=${rest:0:1}
          rest=${rest:1}
          ;;
      esac
    done
    [ -n "$path" ] || return 1
    printf '%s\n' "$path"
  done < "$file"
}

# A worker appends its status to whatever path its brief names, so a ship or
# scout brief may name only <state-dir>/<task-id>.status: the one status file
# of the home about to run it. Print the first status file a status-append
# command names that is not that file and return 0; return 1 when every such
# command names it, including when the brief has none. The directory is
# compared physically, so a symlinked spelling of the same state directory is
# the same file, and an unreadable command or state directory counts as foreign.
fm_brief_foreign_status_file() {  # <file> <state-dir> <task-id>
  local file=$1 state=$2 id=$3 paths path dir want have
  want=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || {
    printf '%s\n' "$state/$id.status"
    return 0
  }
  if ! paths=$(fm_brief_status_append_paths "$file"); then
    printf '%s\n' 'an unreadable status-append command'
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      /*) ;;
      *) printf '%s\n' "$path"; return 0 ;;
    esac
    if [ "${path##*/}" != "$id.status" ]; then
      printf '%s\n' "$path"
      return 0
    fi
    dir=${path%/*}
    have=$(CDPATH='' cd -- "${dir:-/}" 2>/dev/null && pwd -P) || {
      printf '%s\n' "$path"
      return 0
    }
    if [ "$have" != "$want" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done <<EOF
$paths
EOF
  return 1
}
