# Architecture and implementation guide

This file maps the repository's features to concrete files and code paths. It is intended for AI agents and maintainers that need to modify the tool safely.

## Repository map

| Path | Role |
| --- | --- |
| `install.sh` | Installs scripts, wrapper symlinks, and the managed bash PATH block. |
| `uninstall.sh` | Removes installed files, notify-owned symlinks, and the managed PATH block. |
| `src/windows-notify.sh` | WSL entrypoint used by Codex/OMX completion hooks. Stages and invokes PowerShell. |
| `src/windows-notify.ps1` | Windows-side notification, foreground sampling, suppression decision, and logging. |
| `src/register-tab-identity.sh` | WSL helper that calls the PowerShell registration helper. |
| `src/register-tab-identity.ps1` | Samples current Windows Terminal tab RuntimeId and writes the identity store. |
| `src/notify-launch.sh` | Launch wrapper for `codex` and `omx`; registers tab identity before execing the real command. |
| `templates/omx-config.notifications.json` | Example OMX notification config. |
| `tests/verify-fixtures.sh` | Fixture-based decision tests that do not require a live Windows Terminal foreground. |
| `tools/*.sh`, `tools/*.ps1` | Manual UIA inspection tools for Windows Terminal tab behavior. |
| `docs/DESIGN.md` | Product behavior, feature design, and safety principles. |

## End-to-end flows

### Install flow

1. User or agent runs `./install.sh` from the cloned repo.
2. Scripts are copied to `~/.codex/bin`.
3. `codex` and `omx` symlinks are created in `~/.codex/bin` and, when safe, `~/.local/bin`.
4. A managed `~/.codex/bin` PATH block is appended to `~/.bashrc` if missing.
5. User opens a new shell so command lookup can route through the wrappers.

The managed shell block is bounded by:

```text
# >>> omx-windows-notify PATH >>>
# <<< omx-windows-notify PATH <<<
```

Only this block should be removed by `uninstall.sh`.

### Launch registration flow

1. User runs `codex` or `omx` in a Windows Terminal tab.
2. Shell resolves the command to `~/.codex/bin/codex` or `~/.codex/bin/omx`, which are symlinks to `src/notify-launch.sh` after install.
3. `notify-launch.sh` determines the invoked command name.
4. If `WT_SESSION` exists and registration is enabled, it calls `register-tab-identity.sh`.
5. `register-tab-identity.sh` stages `register-tab-identity.ps1` into a Windows-local temp path under `%LOCALAPPDATA%\omx-windows-notify` and runs it with `pwsh.exe`.
6. `register-tab-identity.ps1` reads the foreground Windows Terminal selected tab RuntimeId through UI Automation and updates `tab-identities.json`.
7. `notify-launch.sh` removes wrapper directories from `PATH` and `exec`s the real `codex` or `omx` binary.

Registration failures are non-fatal. If registration cannot prove the current tab, the agent still launches normally.

### Completion notification flow

1. Codex/OMX completion hook calls `~/.codex/bin/windows-notify.sh`.
2. `windows-notify.sh` may create a short-lived title marker fallback unless disabled.
3. `windows-notify.sh` stages `windows-notify.ps1` into a Windows-local temp path and runs it with `pwsh.exe`.
4. `windows-notify.ps1` samples the foreground app/window/tab.
5. It computes a decision: `notify` or `suppress`.
6. It writes a JSONL decision record.
7. If decision is `notify` and dry-run is not enabled, it shows the Windows popup and plays sound.

## `windows-notify.ps1` decision order

The decision logic should remain conservative:

1. If focus-aware mode is disabled: `notify` with `focus_aware_disabled`.
2. If foreground app is not Windows Terminal: `notify` with `foreground_not_terminal`.
3. Try RuntimeId identity:
   - no `WT_SESSION` or no mapping: continue to fallback;
   - stale or incomplete mapping: continue to fallback;
   - selected RuntimeId equals mapped RuntimeId: `suppress` with `same_terminal_tab_runtime_id`;
   - selected RuntimeId differs from mapped RuntimeId: `notify` with `terminal_tab_runtime_id_mismatch`.
4. Try strong title fallback:
   - selected tab text matches explicit target/title marker: `suppress` with `same_terminal_tab`;
   - strong title exists but does not match: `notify` with `terminal_tab_mismatch`;
   - no strong title key: `notify` with `no_strong_target_key`.

Do not add suppression based on weak fields. Log weak fields for diagnostics only.

## Identity store

Default path:

```text
%LOCALAPPDATA%\omx-windows-notify\tab-identities.json
```

Expected shape:

```json
{
  "version": 1,
  "updatedAt": "ISO timestamp",
  "records": {
    "<WT_SESSION>": {
      "wtSession": "<WT_SESSION>",
      "runtimeId": "42.123.4.5",
      "tabName": "diagnostic only",
      "tabRect": "x,y,width,height",
      "windowHandle": 12345,
      "terminalPid": 1234,
      "terminalProcess": "WindowsTerminal",
      "windowTitle": "diagnostic only",
      "tty": "/dev/pts/N",
      "sourceCommand": "codex",
      "createdAt": "ISO timestamp",
      "updatedAt": "ISO timestamp",
      "expiresAt": "ISO timestamp"
    }
  }
}
```

RuntimeIds are runtime-scoped and should expire. Do not treat old records as durable machine identity.

## Environment variables

| Variable | Used by | Effect |
| --- | --- | --- |
| `OMX_WINDOWS_NOTIFY_FOCUS_AWARE=0` | notify | Always notify. |
| `OMX_WINDOWS_NOTIFY_NO_NOTIFY=1` | notify | Dry-run: print/log decision without popup/sound. |
| `OMX_WINDOWS_NOTIFY_SOUND=none` | notify | Disable sound while keeping popup. |
| `OMX_WINDOWS_NOTIFY_REGISTER_TAB_IDENTITY=0` | launch wrapper | Skip RuntimeId registration. |
| `OMX_WINDOWS_NOTIFY_REGISTER_QUIET=0` | registration wrapper | Print registration JSON. |
| `OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0` | notify shell wrapper | Disable title-marker fallback. |
| `OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH=...` | notify/register | Override identity store path, mainly for tests. |
| `OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON=...` | notify tests | Use fixture foreground data instead of live foreground sampling. |

## Testing strategy

Run the standard local checks after modifying behavior:

```bash
bash -n src/*.sh install.sh uninstall.sh tests/*.sh tools/*.sh
bash tests/verify-fixtures.sh
pwsh.exe -NoProfile -Command '$files=@("src/windows-notify.ps1","src/register-tab-identity.ps1","tools/sample-terminal-tabs.ps1","tools/roundtrip-terminal-tabs.ps1"); foreach($f in $files){ $null=[scriptblock]::Create((Get-Content -Raw $f)); "parse ok $f" }'
```

Fixture tests should cover:

- non-Terminal foreground notifies;
- same RuntimeId suppresses;
- different RuntimeId with same visible tab name notifies;
- stale RuntimeId mapping falls back safely;
- title fallback still works;
- no strong identity notifies.

Live tests require Windows Terminal:

1. Open a new shell after install.
2. Start `codex` or `omx` from that shell.
3. Complete a task while focused on the same tab: expect `same_terminal_tab_runtime_id` and no popup/sound.
4. Complete a task after switching to another tab or app: expect notification.

## Modification rules for future agents

- Keep README user-oriented. Put detailed behavior here or in `docs/DESIGN.md`.
- Keep install/uninstall reversible. If adding shell config, mark it with stable start/end comments.
- Prefer adding fixture tests before changing `windows-notify.ps1` decision behavior.
- Preserve `pwsh.exe` as the Windows bridge unless the user explicitly asks otherwise.
- Avoid committing machine-specific examples, absolute local paths, usernames, runtime logs, or generated identity stores.

## Feature implementation reference

Use this section when modifying one feature at a time.

### Install/uninstall and PATH wrappers

Purpose: make future `codex` and `omx` launches pass through tab identity registration without permanently replacing the real commands.

Entrypoints: `./install.sh`, `./uninstall.sh`.

Files involved: `install.sh`, `uninstall.sh`, `src/notify-launch.sh`.

Inputs/env vars: `CODEX_HOME`, `OMX_WINDOWS_NOTIFY_COMMAND_BIN`, `HOME`, `PATH`.

Runtime data written: installed scripts and symlinks under `~/.codex/bin`, optional symlinks under `~/.local/bin`, and a marker-bounded `~/.bashrc` PATH block.

Decision/failure behavior: install skips existing non-owned command files instead of overwriting them. Uninstall removes only symlinks that point to this project's launcher.

Tests to run: shell syntax checks, temp HOME install/uninstall roundtrip, and `bash -ic 'command -v codex; command -v omx'`.

Modification cautions: never remove unrelated shell rc content; keep start/end markers stable.

### Codex/OMX trigger wiring

Purpose: call the notify entrypoint when an agent task completes.

Entrypoints: user-managed `~/.codex/hooks.json`, `~/.codex/.omx-config.json`, and optionally `~/.codex/config.toml` if OMX notify routing is used.

Files involved: `README.md`, `templates/omx-config.notifications.json`, `src/windows-notify.sh`.

Inputs/env vars: Codex `CODEX_THREAD_ID`, current `PWD`, OMX template values `{{event}}`, `{{instruction}}`, `{{sessionId}}`, `{{projectPath}}`.

Runtime data written: decision log only.

Decision/failure behavior: this repo documents snippets but does not overwrite hook/config files automatically.

Tests to run: dry run notify command and inspect `notify-decisions.jsonl`.

Modification cautions: agents should merge snippets into existing config instead of replacing unrelated hooks.

### WSL to PowerShell bridge

Purpose: run Windows UI Automation and NotifyIcon code from WSL reliably.

Entrypoints: `src/windows-notify.sh`, `src/register-tab-identity.sh`.

Files involved: both shell wrappers plus their matching `.ps1` files.

Inputs/env vars: `pwsh.exe` on PATH, WSL `wslpath`, Windows `%LOCALAPPDATA%`.

Runtime data written: temporary staged PowerShell scripts under `%LOCALAPPDATA%\omx-windows-notify`.

Decision/failure behavior: scripts stage to a Windows-local path first, then invoke `pwsh.exe -NoProfile -ExecutionPolicy Bypass`.

Tests to run: shell syntax and PowerShell scriptblock parse checks.

Modification cautions: keep PowerShell 7 as `pwsh.exe`; do not switch to `powershell.exe` unless explicitly requested.

### RuntimeId tab identity

Purpose: distinguish Windows Terminal tabs even when visible tab titles are identical.

Entrypoints: `src/notify-launch.sh` -> `src/register-tab-identity.sh` -> `src/register-tab-identity.ps1`.

Files involved: registration scripts and `src/windows-notify.ps1` identity lookup functions.

Inputs/env vars: `WT_SESSION`, `OMX_WINDOWS_NOTIFY_REGISTER_TAB_IDENTITY`, `OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH`, `OMX_WINDOWS_NOTIFY_TAB_IDENTITY_TTL_HOURS`.

Runtime data written: `%LOCALAPPDATA%\omx-windows-notify\tab-identities.json`.

Decision/failure behavior: missing foreground Terminal, missing `WT_SESSION`, unavailable UIA, or missing selected RuntimeId skips registration without blocking the real command.

Tests to run: fixture tests for same/mismatched RuntimeId and live Windows Terminal tests.

Modification cautions: RuntimeId is runtime-scoped. Keep TTL handling and never treat tab name as a strong identity.

### Focus-aware notify decision

Purpose: decide whether completion should notify or suppress.

Entrypoints: `src/windows-notify.ps1` function `Get-NotifyDecision`.

Files involved: `src/windows-notify.ps1`, `tests/verify-fixtures.sh`.

Inputs/env vars: `WT_SESSION`, fixture env vars, focus-aware toggles.

Runtime data written: `notify-decisions.jsonl`.

Decision/failure behavior: fail open to notify unless same-tab RuntimeId or strong fallback match is proven.

Tests to run: `bash tests/verify-fixtures.sh` after any decision change.

Modification cautions: a valid RuntimeId mismatch must remain decisive and notify.

### Title-marker fallback and tmux behavior

Purpose: provide a weaker same-tab signal when RuntimeId registration is unavailable.

Entrypoints: `src/windows-notify.sh` title marker section and `src/windows-notify.ps1` strong title matching.

Files involved: `src/windows-notify.sh`, `src/windows-notify.ps1`.

Inputs/env vars: `OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER`, `OMX_WINDOWS_NOTIFY_TARGET_TAB`, `OMX_WINDOWS_NOTIFY_TITLE_MARKER_SETTLE_SECONDS`, `TMUX`.

Runtime data written: temporary terminal title state only; it should be restored.

Decision/failure behavior: title-marker match can suppress only when RuntimeId identity is unavailable or inconclusive.

Tests to run: fixture title fallback tests and live tmux smoke tests when changing tmux logic.

Modification cautions: avoid long-lived or constantly refreshed visible title changes unless the user explicitly accepts that tradeoff.

### Popup and sound

Purpose: provide the actual Windows reminder.

Entrypoints: `src/windows-notify.ps1` function `Show-Notification`.

Files involved: `src/windows-notify.ps1`.

Inputs/env vars: `OMX_WINDOWS_NOTIFY_SOUND`, PowerShell `System.Windows.Forms`, `%WINDIR%\Media`.

Runtime data written: none.

Decision/failure behavior: missing sound file falls back to system asterisk. `Sound=none` suppresses sound but not popup.

Tests to run: manual smoke test with visible popup and dry-run tests for decision logic.

Modification cautions: keep dry-run mode side-effect free.

### JSONL decision logging

Purpose: make each notify/suppress decision auditable.

Entrypoints: `src/windows-notify.ps1` function `Write-NotifyDecisionLog`.

Files involved: `src/windows-notify.ps1`, `.gitignore`, `README.md` privacy notes.

Inputs/env vars: `OMX_WINDOWS_NOTIFY_LOG_PATH`.

Runtime data written: `%LOCALAPPDATA%\omx-windows-notify\notify-decisions.jsonl` by default.

Decision/failure behavior: log write failures should not block notification behavior.

Tests to run: dry run notify and inspect the emitted JSON object.

Modification cautions: logs may contain local paths, tab titles, session ids, and foreground process metadata. Do not commit logs.

### Fixture and manual testing tools

Purpose: allow safe regression testing without requiring a live foreground Windows Terminal for every change.

Entrypoints: `tests/verify-fixtures.sh`, `tools/sample-terminal-tabs.sh`, `tools/roundtrip-terminal-tabs.sh`.

Files involved: test and tool scripts.

Inputs/env vars: `OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON`, `OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH`, `OMX_WINDOWS_NOTIFY_NO_NOTIFY`.

Runtime data written: temporary files under the test temp directory; manual tools may only print samples.

Decision/failure behavior: tests should fail loudly on decision reason changes.

Tests to run: the fixture script itself plus shell/PowerShell parse checks.

Modification cautions: keep fixture examples synthetic and free of local usernames or machine-specific data.
