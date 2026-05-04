#!/usr/bin/env bash
set -euo pipefail

event_name="${1:-stop}"
input_body="${2:-Task finished}"
session_id="${3:-}"
project_path="${4:-}"
sound="${5:-${OMX_WINDOWS_NOTIFY_SOUND:-Windows Notify Calendar.wav}}"
backend="${OMX_WINDOWS_NOTIFY_BACKEND:-toast}"
max_body_chars="${OMX_WINDOWS_NOTIFY_BODY_MAX_CHARS:-220}"

read_hook_session_candidates() {
  [ ! -t 0 ] || return 0
  node -e '
const fs = require("fs");
let raw = "";
try { raw = fs.readFileSync(0, "utf8"); } catch (_) {}
raw = String(raw || "").trim();
if (!raw) process.exit(0);
let payload;
try { payload = JSON.parse(raw); } catch (_) { process.exit(0); }
const wanted = new Set(["session_id", "sessionId", "thread_id", "threadId", "codex_session_id", "native_session_id", "nativeSessionId"]);
const out = [];
function add(value) {
  value = String(value || "").trim();
  if (value && !out.includes(value)) out.push(value);
}
function visit(value, depth = 0) {
  if (!value || typeof value !== "object" || depth > 4) return;
  if (Array.isArray(value)) {
    for (const item of value) visit(item, depth + 1);
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (wanted.has(key)) add(item);
    if (item && typeof item === "object") visit(item, depth + 1);
  }
}
visit(payload);
process.stdout.write(out.join("\n"));
' 2>/dev/null || true
}

hook_session_candidates="${OMX_WINDOWS_NOTIFY_SESSION_CANDIDATES:-$(read_hook_session_candidates)}"

resolve_last_user_message() {
  case "${OMX_WINDOWS_NOTIFY_USE_HISTORY_BODY:-1}" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      return 1
      ;;
  esac

  local history_path="${OMX_WINDOWS_NOTIFY_HISTORY_PATH:-${CODEX_HOME:-$HOME/.codex}/history.jsonl}"
  [ -f "$history_path" ] || return 1

  # shellcheck disable=SC2086
  python3 - "$history_path" "$max_body_chars" "$session_id" "${CODEX_THREAD_ID:-}" "${CODEX_SESSION_ID:-}" "${SESSION_ID:-}" $hook_session_candidates <<'PYBODY'
import json
import sys
from pathlib import Path

history_path = Path(sys.argv[1])
try:
    max_chars = int(sys.argv[2])
except Exception:
    max_chars = 220
candidates = []
for value in sys.argv[3:]:
    value = (value or '').strip()
    if value and value not in candidates:
        candidates.append(value)

last_exact = None
try:
    with history_path.open('r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except Exception:
                continue
            text = str(record.get('text') or '').strip()
            if not text:
                continue
            record_session = str(record.get('session_id') or '').strip()
            if candidates and record_session in candidates:
                last_exact = text
except Exception:
    sys.exit(1)

text = last_exact or ''
if not text:
    sys.exit(1)
text = ' '.join(text.split())
if max_chars > 0 and len(text) > max_chars:
    text = text[:max(1, max_chars - 1)].rstrip() + '…'
print(text)
PYBODY
}

title="${OMX_WINDOWS_NOTIFY_TITLE:-Task Complete}"
body="$(resolve_last_user_message 2>/dev/null || true)"
if [ -z "$body" ]; then
  body="$input_body"
fi

focus_aware_enabled=1
case "${OMX_WINDOWS_NOTIFY_FOCUS_AWARE:-1}" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF)
    focus_aware_enabled=0
    ;;
esac

title_marker=""
title_marker_stream=""
title_marker_target="${OMX_WINDOWS_NOTIFY_TARGET_TAB:-}"
title_marker_source="explicit_target_tab"
use_title_marker="${OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER:-1}"
tmux_title_old_set=""
tmux_title_old_string=""
tmux_title_marker_applied=0
tmux_title_keepalive_pid=""
tmux_title_keepalive_stop=""

restore_title_marker() {
  if [ -n "$tmux_title_keepalive_stop" ]; then
    : > "$tmux_title_keepalive_stop" 2>/dev/null || true
  fi
  if [ -n "$tmux_title_keepalive_pid" ]; then
    wait "$tmux_title_keepalive_pid" 2>/dev/null || true
  fi

  if [ "$tmux_title_marker_applied" = "1" ] && command -v tmux >/dev/null 2>&1; then
    if [ -n "$tmux_title_old_set" ]; then
      tmux set-option -q set-titles "$tmux_title_old_set" 2>/dev/null || true
    else
      tmux set-option -q -u set-titles 2>/dev/null || true
    fi
    if [ -n "$tmux_title_old_string" ]; then
      tmux set-option -q set-titles-string "$tmux_title_old_string" 2>/dev/null || true
    else
      tmux set-option -q -u set-titles-string 2>/dev/null || true
    fi
  fi

  if [ -n "$title_marker" ] && [ "$title_marker_stream" != "tmux" ]; then
    case "$title_marker_stream" in
      tty) { printf '\033[23;0t' > /dev/tty; } 2>/dev/null || true ;;
      stdout) printf '\033[23;0t' || true ;;
      stderr) printf '\033[23;0t' >&2 || true ;;
    esac
  fi
}
trap restore_title_marker EXIT

if [ "$focus_aware_enabled" = "1" ] && [ -z "$title_marker_target" ]; then
  case "$use_title_marker" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      ;;
    *)
      safe_session="$(printf '%s' "${session_id:-session}" | tr -cd '[:alnum:]_-' | cut -c1-16)"
      [ -n "$safe_session" ] || safe_session="session"
      candidate_marker="omx-notify-${safe_session}-$$-$(date +%H%M%S%3N)"
      # If the agent is inside tmux, direct OSC title escapes are normally
      # consumed by tmux when set-titles is off. Temporarily ask tmux itself to
      # set the outer client title so Windows Terminal UIA can see the marker.
      if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux_title_old_set="$(tmux show-option -qv set-titles 2>/dev/null || true)"
        tmux_title_old_string="$(tmux show-option -qv set-titles-string 2>/dev/null || true)"
        if tmux set-option -q set-titles on 2>/dev/null && \
           tmux set-option -q set-titles-string "$candidate_marker" 2>/dev/null; then
          title_marker_stream="tmux"
          tmux_title_marker_applied=1
          tmux refresh-client -S 2>/dev/null || true
          tmux_title_keepalive_stop="$(mktemp "${TMPDIR:-/tmp}/omx-notify-title.XXXXXX")"
          rm -f "$tmux_title_keepalive_stop"
          (
            while [ ! -e "$tmux_title_keepalive_stop" ]; do
              tmux set-option -q set-titles on 2>/dev/null || true
              tmux set-option -q set-titles-string "$candidate_marker" 2>/dev/null || true
              tmux refresh-client -S 2>/dev/null || true
              sleep 0.08
            done
          ) &
          tmux_title_keepalive_pid="$!"
        fi
      fi
      # Save current title where supported, set a short-lived marker for Windows Terminal UIA,
      # then restore after the PowerShell decision returns. Only emit to an actual
      # terminal sink; never write escape sequences into pipes/command substitutions.
      if [ -z "$title_marker_stream" ]; then
        if { printf '\033[22;0t\033]2;%s\007\033]0;%s\007' "$candidate_marker" "$candidate_marker" > /dev/tty; } 2>/dev/null; then
          title_marker_stream="tty"
        elif [ -t 1 ]; then
          printf '\033[22;0t\033]2;%s\007\033]0;%s\007' "$candidate_marker" "$candidate_marker"
          title_marker_stream="stdout"
        elif [ -t 2 ]; then
          printf '\033[22;0t\033]2;%s\007\033]0;%s\007' "$candidate_marker" "$candidate_marker" >&2
          title_marker_stream="stderr"
        fi
      fi
      if [ -n "$title_marker_stream" ]; then
        title_marker="$candidate_marker"
        title_marker_target="$title_marker"
        title_marker_source="${title_marker_stream}_title_marker"
        sleep "${OMX_WINDOWS_NOTIFY_TITLE_MARKER_SETTLE_SECONDS:-0.45}"
      fi
      ;;
  esac
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installed_ps1="$script_dir/windows-notify.ps1"
if [ ! -f "$installed_ps1" ]; then
  installed_ps1="$HOME/.codex/bin/windows-notify.ps1"
fi

# Stage to a Windows-local path before running UIAutomation / NotifyIcon code.
# This mirrors the focus prototype's stability pattern without relying on
# WSL->Windows environment propagation.
win_local_appdata="$(pwsh.exe -NoProfile -Command '[Environment]::GetFolderPath("LocalApplicationData")' | tr -d '\r' | tail -n 1)"
staged_ps1=""
staged_local_ps1=""
if [ -n "$win_local_appdata" ]; then
  local_appdata_path="$(wslpath -u "$win_local_appdata" 2>/dev/null || true)"
  if [ -n "$local_appdata_path" ]; then
    mkdir -p "$local_appdata_path/omx-windows-notify"
    staged_name="windows-notify-$$-${RANDOM}.ps1"
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
  -Title "$title"
  -Body "$body"
  -SessionId "$session_id"
  -ProjectPath "$project_path"
  -Sound "$sound"
  -Backend "$backend"
)

if [ -n "$title_marker_target" ]; then
  args+=( -TargetTab "$title_marker_target" )
  args+=( -TargetTabSource "$title_marker_source" )
fi
if [ -n "${OMX_WINDOWS_NOTIFY_LOG_PATH:-}" ]; then
  args+=( -LogPath "$OMX_WINDOWS_NOTIFY_LOG_PATH" )
fi
if [ -n "${OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON:-}" ]; then
  fixture="$OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON"
  if [ -f "$fixture" ]; then
    fixture="$(wslpath -w "$fixture")"
  fi
  args+=( -ForegroundFixtureJson "$fixture" )
fi
if [ -n "${OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH:-}" ]; then
  identity_path="$OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH"
  case "$identity_path" in
    /*) identity_path="$(wslpath -w "$identity_path" 2>/dev/null || printf '%s' "$identity_path")" ;;
  esac
  args+=( -TabIdentitiesPath "$identity_path" )
fi
if [ "$focus_aware_enabled" = "0" ]; then
  args+=( -DisableFocusAware )
fi
case "${OMX_WINDOWS_NOTIFY_NO_NOTIFY:-0}" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    args+=( -NoNotify )
    ;;
esac

set +e
pwsh.exe "${args[@]}"
status=$?
set -e
restore_title_marker
trap - EXIT
if [ -n "$staged_local_ps1" ]; then
  rm -f "$staged_local_ps1"
fi
exit "$status"
