#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src_ps1="$(wslpath -w "$script_dir/sample-terminal-tabs.ps1")"
win_ps1="$(pwsh.exe -NoProfile -Command "\$destDir = Join-Path \$env:LOCALAPPDATA 'omx-windows-notify'; New-Item -ItemType Directory -Force -Path \$destDir | Out-Null; \$dest = Join-Path \$destDir 'sample-terminal-tabs.ps1'; Copy-Item -LiteralPath '$src_ps1' -Destination \$dest -Force; Write-Output \$dest" | tr -d '\r')"
exec pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$win_ps1" "$@"
