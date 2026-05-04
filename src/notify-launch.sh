#!/usr/bin/env bash
set -euo pipefail

invoked_name="$(basename -- "$0")"
case "$invoked_name" in
  codex|omx) command_name="$invoked_name" ;;
  *)
    command_name="${OMX_WINDOWS_NOTIFY_LAUNCH_COMMAND:-}"
    if [ -z "$command_name" ]; then
      echo "notify-launch.sh: cannot infer command name from '$invoked_name'" >&2
      exit 127
    fi
    ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

remove_path_entries() {
  local remove_a="$1"
  local remove_b="$2"
  local out=""
  local entry
  IFS=':' read -r -a parts <<< "${PATH:-}"
  for entry in "${parts[@]}"; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "$remove_a"|"$remove_b") continue ;;
    esac
    if [ -z "$out" ]; then out="$entry"; else out="$out:$entry"; fi
  done
  printf '%s' "$out"
}

codex_bin="${CODEX_HOME:-$HOME/.codex}/bin"
local_bin="$HOME/.local/bin"
search_path="$(remove_path_entries "$codex_bin" "$local_bin")"
real_command="$(PATH="$search_path" command -v "$command_name" 2>/dev/null || true)"
if [ -z "$real_command" ]; then
  echo "notify-launch.sh: could not find real '$command_name' after excluding $codex_bin and $local_bin" >&2
  exit 127
fi

case "${OMX_WINDOWS_NOTIFY_REGISTER_TAB_IDENTITY:-1}" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF)
    ;;
  *)
    if [ -n "${WT_SESSION:-}" ]; then
      register_script="$codex_bin/register-tab-identity.sh"
      if [ ! -f "$register_script" ]; then register_script="$script_dir/register-tab-identity.sh"; fi
      if [ -f "$register_script" ]; then
        OMX_WINDOWS_NOTIFY_REGISTER_QUIET="${OMX_WINDOWS_NOTIFY_REGISTER_QUIET:-1}" \
          bash "$register_script" "$command_name" >/dev/null 2>&1 || true
      fi
    fi
    ;;
esac

PATH="$search_path" exec "$real_command" "$@"
