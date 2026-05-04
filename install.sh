#!/usr/bin/env bash
set -euo pipefail

src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
local_bin="${OMX_WINDOWS_NOTIFY_COMMAND_BIN:-$HOME/.local/bin}"
mkdir -p "$codex_home/bin" "$local_bin"

install -m 0755 "$src_dir/src/windows-notify.sh" "$codex_home/bin/windows-notify.sh"
install -m 0644 "$src_dir/src/windows-notify.ps1" "$codex_home/bin/windows-notify.ps1"
install -m 0755 "$src_dir/src/register-tab-identity.sh" "$codex_home/bin/register-tab-identity.sh"
install -m 0644 "$src_dir/src/register-tab-identity.ps1" "$codex_home/bin/register-tab-identity.ps1"
install -m 0755 "$src_dir/src/notify-launch.sh" "$codex_home/bin/notify-launch.sh"

installed_wrappers=()
skipped_wrappers=()
for wrapper_bin in "$codex_home/bin" "$local_bin"; do
for name in codex omx; do
  target="$wrapper_bin/$name"
  desired="$codex_home/bin/notify-launch.sh"
  if [ -e "$target" ] || [ -L "$target" ]; then
    current="$(readlink "$target" 2>/dev/null || true)"
    if [ "$current" = "$desired" ]; then
      ln -sfn "$desired" "$target"
      installed_wrappers+=("$target -> $desired")
    else
      skipped_wrappers+=("$target exists; left unchanged")
    fi
  else
    ln -s "$desired" "$target"
    installed_wrappers+=("$target -> $desired")
  fi
done
done

path_block_start="# >>> omx-windows-notify PATH >>>"
path_block_end="# <<< omx-windows-notify PATH <<<"
bashrc="$HOME/.bashrc"
path_block="${path_block_start}
case ":\$PATH:" in
  *:"\$HOME/.codex/bin":*) ;;
  *) export PATH="\$HOME/.codex/bin:\$PATH" ;;
esac
${path_block_end}"
if [ -f "$bashrc" ]; then
  if ! grep -Fq "$path_block_start" "$bashrc"; then
    printf '\n%s\n' "$path_block" >> "$bashrc"
  fi
fi

# Install notification config only when no file exists, to avoid overwriting user settings.
if [ ! -f "$codex_home/.omx-config.json" ]; then
  install -m 0644 "$src_dir/templates/omx-config.notifications.json" "$codex_home/.omx-config.json"
fi

cat <<MSG
Installed Windows notify scripts to:
  $codex_home/bin/windows-notify.sh
  $codex_home/bin/windows-notify.ps1
  $codex_home/bin/register-tab-identity.sh
  $codex_home/bin/register-tab-identity.ps1
  $codex_home/bin/notify-launch.sh
MSG

if [ "${#installed_wrappers[@]}" -gt 0 ]; then
  printf '\nInstalled command wrappers for future launches:\n'
  printf '  %s\n' "${installed_wrappers[@]}"
fi
if [ "${#skipped_wrappers[@]}" -gt 0 ]; then
  printf '\nSkipped command wrappers to avoid overwriting existing files:\n'
  printf '  %s\n' "${skipped_wrappers[@]}"
fi

cat <<MSG

The wrappers register Windows Terminal RuntimeId identity before launching the real codex/omx.
They take effect when $codex_home/bin (preferred) or $local_bin appears before the real codex/omx directory in PATH.
A managed PATH block is present in $bashrc for future interactive bash shells.
Current live setup may already contain Stop hook and OMX notify wiring; install.sh does not rewrite hooks.json/config.toml.
MSG
