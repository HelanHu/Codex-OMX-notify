# Design: Codex-OMX-notify

This document explains what the tool does, why it exists, and how the runtime flow should behave. It is written for both maintainers and AI coding agents that need to install, debug, or modify this repository after cloning it in a new environment.

## Problem

Codex CLI and oh-my-codex (OMX) can run long tasks in a WSL terminal. When a task finishes, the user often wants a Windows reminder if they have moved away. But if they are still looking at the same terminal tab, a popup and sound are noisy.

The goal is:

- notify when the task finished in the background from the user's point of view;
- suppress when the user is already focused on the same Windows Terminal tab;
- support both Codex and OMX completion paths;
- keep installation reversible and easy for an agent to automate.

## Core behavior

| Foreground state at completion | Task origin known? | Result |
| --- | --- | --- |
| Non-Terminal app focused | any | Notify |
| Windows Terminal focused on same registered tab | yes | Suppress |
| Windows Terminal focused on a different tab | yes | Notify |
| Windows Terminal focused but no strong origin identity | no | Notify |
| Focus-aware mode disabled | ignored | Notify |

The design intentionally fails open to notification. If the code cannot prove that the user is looking at the same tab, it should notify rather than suppress.

## Main features

### 1. Windows notification bridge

WSL cannot directly show a native Windows balloon notification. The shell wrapper calls `pwsh.exe` / PowerShell 7 and runs a Windows-side script that uses:

- BurntToast for Windows Toast notification center notifications by default (`Duration=Long`, visible in notification center);
- `System.Windows.Forms.NotifyIcon` for the fallback tray balloon;
- `System.Media.SoundPlayer` for the configured sound in balloon mode;
- silent Toast support when `OMX_WINDOWS_NOTIFY_SOUND=none`;
- a 21-second fallback balloon wait after `ShowBalloonTip(20000)`.

### 2. Codex and OMX completion triggers

The repo provides the notification command. The user's Codex/OMX configuration decides when to call it. Current completion notifications use source-tagged titles such as `[Codex] Task Complete` and `[OMX] Task Complete`; the source should be passed explicitly by config when possible and is otherwise inferred from OMX runtime environment variables, falling back to Codex; the body is resolved from the last user message for the matching session in `~/.codex/history.jsonl`, truncated to a practical length, with the hook body as fallback. The script also parses Codex hook stdin JSON for `session_id` / `thread_id`; it does not fall back to another session's global latest prompt when no session identity is available.

Recommended trigger surfaces:

- Codex native `Stop` hook calls `~/.codex/bin/windows-notify.sh`.
- OMX `custom_cli_command` calls `~/.codex/bin/windows-notify.sh` for `session-end` and `stop` events.

The tool does not overwrite existing hook files automatically because those files may already contain user-specific hooks.

### 3. RuntimeId-based tab identity

Windows Terminal tab titles are not reliable identity keys. Two tabs may have the same title, and shells or agent tools may overwrite titles.

The primary identity is the Windows UI Automation `TabItem.GetRuntimeId()` of the selected Windows Terminal tab. The launch wrapper records:

```json
{
  "wtSession": "WT_SESSION value",
  "runtimeId": "UIA TabItem runtime id",
  "tabName": "diagnostic only",
  "windowHandle": 12345,
  "terminalPid": 1234,
  "sourceCommand": "codex or omx",
  "expiresAt": "timestamp"
}
```

This mapping is stored at:

```text
%LOCALAPPDATA%\omx-windows-notify\tab-identities.json
```

At completion time, the notify script compares the current foreground selected tab RuntimeId with the record for the completion process's `WT_SESSION`.

Important rule: `WT_SESSION` is only a lookup key. It is not proof by itself. The proof is the RuntimeId match.

### 4. Fallback title marker

If RuntimeId identity is unavailable, the shell wrapper can briefly set a generated terminal title marker and ask PowerShell to compare it with the selected Windows Terminal tab text.

This fallback exists for compatibility only. It is weaker because titles can collide or be overwritten. A valid RuntimeId mismatch must not be overridden by a title match.

### 5. Decision logging

Each invocation writes one compact JSON object to:

```text
%LOCALAPPDATA%\omx-windows-notify\notify-decisions.jsonl
```

Logs are diagnostic and should not be committed. They help verify reasons such as:

- `same_terminal_tab_runtime_id`
- `terminal_tab_runtime_id_mismatch`
- `foreground_not_terminal`
- `no_strong_target_key`

## Installation design

`install.sh` does three things:

1. Copies scripts into `~/.codex/bin`.
2. Installs notify-owned `codex` and `omx` wrapper symlinks when safe.
3. Adds a marker-bounded `~/.codex/bin` PATH block to `~/.bashrc` for future interactive shells.

The wrapper symlinks call `notify-launch.sh`, which registers tab identity and then execs the real `codex` or `omx` command after removing wrapper directories from `PATH` to avoid recursion.

`uninstall.sh` removes only files and shell blocks owned by this project. It does not delete unrelated user commands or rewrite hook configs.

## Safety principles

- Use PowerShell 7 (`pwsh.exe`), not Windows PowerShell 5.1.
- Never suppress from weak metadata such as tab title, cwd, project path, tmux pane, or session id alone.
- Keep hooks user-controlled; document config snippets instead of overwriting hook files.
- Keep generated runtime data under `%LOCALAPPDATA%\omx-windows-notify` and out of git.
- Prefer reversible changes and marker-bounded shell rc edits.
