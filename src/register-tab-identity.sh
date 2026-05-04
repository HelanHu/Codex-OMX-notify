#!/usr/bin/env bash
set -euo pipefail

source_command="${1:-${OMX_WINDOWS_NOTIFY_SOURCE_COMMAND:-unknown}}"
wt_session="${WT_SESSION:-}"
tty_name=""
tty_name="$(tty 2>/dev/null || true)"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installed_ps1="$script_dir/register-tab-identity.ps1"
if [ ! -f "$installed_ps1" ]; then
  installed_ps1="$HOME/.codex/bin/register-tab-identity.ps1"
fi

win_local_appdata="$(pwsh.exe -NoProfile -Command '[Environment]::GetFolderPath("LocalApplicationData")' | tr -d '\r' | tail -n 1)"
staged_ps1=""
staged_local_ps1=""
if [ -n "$win_local_appdata" ]; then
  local_appdata_path="$(wslpath -u "$win_local_appdata" 2>/dev/null || true)"
  if [ -n "$local_appdata_path" ]; then
    mkdir -p "$local_appdata_path/omx-windows-notify"
    staged_name="register-tab-identity-$$-${RANDOM}.ps1"
    staged_local_ps1="$local_appdata_path/omx-windows-notify/$staged_name"
    cp -f "$installed_ps1" "$staged_local_ps1"
    staged_ps1="$win_local_appdata\\omx-windows-notify\\$staged_name"
  fi
fi

if [ -z "$staged_ps1" ]; then
  staged_ps1="$(wslpath -w "$installed_ps1")"
fi

args=(
  -NoProfile
  -ExecutionPolicy Bypass
  -File "$staged_ps1"
  -WtSession "$wt_session"
  -SourceCommand "$source_command"
  -Tty "$tty_name"
)
if [ -n "${OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH:-}" ]; then
  args+=( -IdentityPath "$OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH" )
fi
if [ -n "${OMX_WINDOWS_NOTIFY_TAB_IDENTITY_TTL_HOURS:-}" ]; then
  args+=( -TtlHours "$OMX_WINDOWS_NOTIFY_TAB_IDENTITY_TTL_HOURS" )
fi
case "${OMX_WINDOWS_NOTIFY_REGISTER_QUIET:-0}" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON) args+=( -Quiet ) ;;
esac

set +e
pwsh.exe "${args[@]}"
status=$?
set -e
if [ -n "$staged_local_ps1" ]; then rm -f "$staged_local_ps1"; fi
exit "$status"
