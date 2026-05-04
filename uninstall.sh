#!/usr/bin/env bash
set -euo pipefail
codex_home="${CODEX_HOME:-$HOME/.codex}"
local_bin="${OMX_WINDOWS_NOTIFY_COMMAND_BIN:-$HOME/.local/bin}"
launcher="$codex_home/bin/notify-launch.sh"

for wrapper_bin in "$codex_home/bin" "$local_bin"; do
for name in codex omx; do
  target="$wrapper_bin/$name"
  if [ -L "$target" ] && [ "$(readlink "$target" 2>/dev/null || true)" = "$launcher" ]; then
    rm -f "$target"
  fi
done
done

path_block_start="# >>> omx-windows-notify PATH >>>"
path_block_end="# <<< omx-windows-notify PATH <<<"
bashrc="$HOME/.bashrc"
if [ -f "$bashrc" ] && grep -Fq "$path_block_start" "$bashrc"; then
  python3 - "$bashrc" "$path_block_start" "$path_block_end" <<'PYRM'
import sys
from pathlib import Path
path = Path(sys.argv[1])
start = sys.argv[2]
end = sys.argv[3]
text = path.read_text()
while start in text:
    i = text.index(start)
    j = text.index(end, i) + len(end)
    if i > 0 and text[i-1] == "\n":
        i -= 1
    if j < len(text) and text[j:j+1] == "\n":
        j += 1
    text = text[:i] + text[j:]
path.write_text(text)
PYRM
fi

rm -f \
  "$codex_home/bin/windows-notify.sh" \
  "$codex_home/bin/windows-notify.ps1" \
  "$codex_home/bin/register-tab-identity.sh" \
  "$codex_home/bin/register-tab-identity.ps1" \
  "$codex_home/bin/notify-launch.sh"

cat <<MSG
Removed Windows notify scripts, notify-owned codex/omx wrapper symlinks, and the managed bash PATH block when present.
Manual cleanup may still be needed in:
  $codex_home/hooks.json
  $codex_home/config.toml
  $codex_home/.omx-config.json
Optional Windows runtime data cleanup:
  %LOCALAPPDATA%\\omx-windows-notify\\tab-identities.json
  %LOCALAPPDATA%\\omx-windows-notify\\notify-decisions.jsonl
MSG
