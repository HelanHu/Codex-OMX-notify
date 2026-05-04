# Codex-OMX-notify 🔔

Windows task-complete notifications for **Codex CLI** and **oh-my-codex (OMX)** running in WSL.

It shows a Windows popup + sound when an agent finishes — but stays quiet when you are already looking at the same Windows Terminal tab.

## Features

- **Codex + OMX support** — works with Codex `Stop` hooks and OMX `session-end` / `stop` notifications.
- **Windows Toast notifications** — default backend uses BurntToast via PowerShell 7 and appears in the Windows notification center.
- **Balloon fallback** — simple tray balloon popup remains available with `OMX_WINDOWS_NOTIFY_BACKEND=balloon`.
- **Focus-aware suppression** — no reminder when the completing task belongs to your currently focused Windows Terminal tab.
- **Duplicate tab titles handled** — uses Windows Terminal UI Automation `RuntimeId`, not tab title text, as the primary tab identity.
- **Safe fallback** — if RuntimeId identity is unavailable, falls back to the older short-lived title-marker strategy.
- **Auditable** — every decision is logged as JSONL.
- **Reversible** — uninstall script removes installed files and notify-owned wrappers.

## Requirements

- Windows + WSL
- Windows Terminal recommended
- PowerShell 7 available as `pwsh.exe`
- Codex CLI and/or oh-my-codex installed
- Optional but recommended for Toast: BurntToast PowerShell module; `install.sh` can install it for the current Windows user.


## For AI agents

If a user gives you this repo URL and asks you to set it up, use this checklist:

1. Clone or enter the repo.
2. Run `bash tests/verify-fixtures.sh` to verify the decision logic.
3. Run `./install.sh`.
4. Tell the user to open a new shell so `codex` / `omx` launch wrappers are on `PATH`.
5. Add the Codex Stop hook and/or OMX custom notification snippet from this README, merging with existing config instead of overwriting unrelated hooks.
6. Run a dry run with `OMX_WINDOWS_NOTIFY_NO_NOTIFY=1`.
7. For full uninstall, run `./uninstall.sh` and remove the hook/config snippets that were added.

Do not commit or upload files from `%LOCALAPPDATA%\omx-windows-notify`; they are runtime diagnostics and may contain local paths/session metadata.

## Quick start

```bash
git clone https://github.com/HelanHu/Codex-OMX-notify.git
cd Codex-OMX-notify
./install.sh
```

`install.sh` lets you choose Toast notification center notifications or a simple balloon popup, copies scripts to `~/.codex/bin`, installs safe `codex` / `omx` launch wrappers, and adds a managed `~/.codex/bin` PATH block to `~/.bashrc`.

Open a new shell after installing so future `codex` / `omx` launches can register the current Windows Terminal tab identity.

## Wire notifications

This repo does **not** overwrite your existing Codex/OMX config automatically. Add the hook you need.

### Codex Stop hook

Add a `Stop` command in `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc 'bash \"$HOME/.codex/bin/windows-notify.sh\" stop \"Codex task complete\" \"${CODEX_THREAD_ID:-}\" \"${PWD:-$HOME}\"'",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
```

If you already have a `Stop` hook, add only the command entry instead of replacing the whole file.

### OMX custom notification command

Add or merge this into `~/.codex/.omx-config.json`:

```json
{
  "notifications": {
    "enabled": true,
    "verbosity": "session",
    "custom_cli_command": {
      "enabled": true,
      "command": "bash ~/.codex/bin/windows-notify.sh {{event}} {{instruction}} {{sessionId}} {{projectPath}}",
      "timeout": 15000,
      "instruction": "Task Complete",
      "events": ["session-end", "stop"]
    }
  }
}
```

## How focus suppression works

1. The `codex` / `omx` wrapper records the selected Windows Terminal tab `RuntimeId` for the current `WT_SESSION`.
2. When a task completes, the notify script samples the current foreground Windows Terminal tab.
3. Same `RuntimeId` means you are looking at the task's tab, so popup + sound are suppressed.
4. Different tab or different app means the task is background from your perspective, so you get notified.

This is tab-level by design. It does not try to distinguish panes or multiple agents inside one tab.

## Test

Dry run without popup/sound:

```bash
OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
  bash ~/.codex/bin/windows-notify.sh stop 'notify dry run' dry-run "$HOME"
```

Visible Toast notification:

```bash
bash ~/.codex/bin/windows-notify.sh stop 'Task Complete' smoke "$HOME"
```

Run fixture tests from the repo:

```bash
bash tests/verify-fixtures.sh
```

## Logs

Decision log:

```text
%LOCALAPPDATA%\omx-windows-notify\notify-decisions.jsonl
```

Privacy note: decision logs and tab identity files can include local project paths, terminal titles, session ids, and foreground window metadata. They are ignored by this repo and should not be uploaded publicly.

Inspect recent decisions from WSL:

```bash
pwsh.exe -NoProfile -Command \
  "Get-Content (Join-Path $env:LOCALAPPDATA 'omx-windows-notify\notify-decisions.jsonl') -Tail 20"
```

Useful reasons:

- `same_terminal_tab_runtime_id` — correctly suppressed same-tab completion.
- `terminal_tab_runtime_id_mismatch` — correctly notified from a different tab.
- `foreground_not_terminal` — correctly notified because another app was focused.

## Configuration

| Variable | Meaning |
| --- | --- |
| `OMX_WINDOWS_NOTIFY_FOCUS_AWARE=0` | Disable focus-aware suppression. |
| `OMX_WINDOWS_NOTIFY_NO_NOTIFY=1` | Dry-run: log/print without popup or sound. |
| `OMX_WINDOWS_NOTIFY_BACKEND=toast` | Use Windows Toast notification center notifications. Default. |
| `OMX_WINDOWS_NOTIFY_BACKEND=balloon` | Use the legacy tray balloon popup. |
| `OMX_WINDOWS_NOTIFY_BODY_MAX_CHARS=220` | Max characters from the last user message shown in the notification body. |
| `OMX_WINDOWS_NOTIFY_USE_HISTORY_BODY=0` | Disable last-user-message body lookup and use the hook body argument instead. |
| `OMX_WINDOWS_NOTIFY_SESSION_CANDIDATES=...` | Optional newline/space-separated session ids to match against `~/.codex/history.jsonl`. Normally parsed from hook stdin or args. |
| `OMX_WINDOWS_NOTIFY_SOUND='Windows Notify Calendar.wav'` | Balloon backend sound; use `none` for silent notification. Toast uses the Windows default unless `none` is set. |
| `OMX_WINDOWS_NOTIFY_REGISTER_TAB_IDENTITY=0` | Disable launch-time RuntimeId registration. |
| `OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0` | Disable title-marker fallback. |

## Uninstall

```bash
./uninstall.sh
```

Manual config cleanup may still be needed in:

- `~/.codex/hooks.json`
- `~/.codex/config.toml`
- `~/.codex/.omx-config.json`

Optional Windows runtime cleanup:

```powershell
Remove-Item "$env:LOCALAPPDATA\omx-windows-notify" -Recurse -Force -ErrorAction SilentlyContinue
```

## More detail

- Design guide: [`docs/DESIGN.md`](docs/DESIGN.md)
- Architecture and implementation guide: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
