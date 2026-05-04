#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/nonterminal.json" <<'JSON'
{"process":"notepad","pid":123,"title":"Note","handle":1,"selectedTabs":[],"selectedTabRecords":[],"uiRootName":"","uiRootClass":"","focusedName":"","focusedType":"","focusedClass":""}
JSON

cat > "$tmpdir/terminal.json" <<'JSON'
{"process":"WindowsTerminal","pid":123,"title":"tab-a","path":"C:\\Program Files\\WindowsApps\\Terminal.exe","windowClass":"CASCADIA_HOSTING_WINDOW_CLASS","uiRootClass":"CASCADIA_HOSTING_WINDOW_CLASS","selectedTabs":["tab-a"],"selectedTabRecords":[{"name":"tab-a","runtimeId":"42.100.4.1","rect":"0,0,300,40"}],"focusedName":"","focusedType":"","focusedClass":""}
JSON

cat > "$tmpdir/terminal_same_name_other_runtime.json" <<'JSON'
{"process":"WindowsTerminal","pid":123,"title":"tab-a","path":"C:\\Program Files\\WindowsApps\\Terminal.exe","windowClass":"CASCADIA_HOSTING_WINDOW_CLASS","uiRootClass":"CASCADIA_HOSTING_WINDOW_CLASS","selectedTabs":["tab-a"],"selectedTabRecords":[{"name":"tab-a","runtimeId":"42.100.4.2","rect":"300,0,300,40"}],"focusedName":"","focusedType":"","focusedClass":""}
JSON

cat > "$tmpdir/runtime-identities.json" <<'JSON'
{
  "version": 1,
  "updatedAt": "2099-01-01T00:00:00.0000000+00:00",
  "records": {
    "fixture-session": {
      "wtSession": "fixture-session",
      "runtimeId": "42.100.4.1",
      "tabName": "tab-a",
      "windowHandle": 1,
      "terminalPid": 123,
      "sourceCommand": "test",
      "createdAt": "2099-01-01T00:00:00.0000000+00:00",
      "updatedAt": "2099-01-01T00:00:00.0000000+00:00",
      "expiresAt": "2099-01-02T00:00:00.0000000+00:00"
    }
  }
}
JSON

cat > "$tmpdir/stale-runtime-identities.json" <<'JSON'
{
  "version": 1,
  "updatedAt": "2000-01-01T00:00:00.0000000+00:00",
  "records": {
    "fixture-session": {
      "wtSession": "fixture-session",
      "runtimeId": "42.100.4.1",
      "tabName": "tab-a",
      "expiresAt": "2000-01-02T00:00:00.0000000+00:00"
    }
  }
}
JSON

assert_decision() {
  local output="$1"
  local expected_action="$2"
  local expected_reason="$3"
  local label="$4"

  node -e '
    const rec = JSON.parse(process.argv[1]);
    const expectedAction = process.argv[2];
    const expectedReason = process.argv[3];
    const label = process.argv[4];
    if (rec.action !== expectedAction || rec.reason !== expectedReason) {
      console.error(`FAIL ${label}: expected ${expectedAction}:${expectedReason}`);
      console.error(JSON.stringify(rec, null, 2));
      process.exit(1);
    }
    console.log(`PASS ${label}: ${rec.action}:${rec.reason}`);
  ' "$output" "$expected_action" "$expected_reason" "$label"
}

run_case() {
  local label="$1"
  local expected_action="$2"
  local expected_reason="$3"
  local fixture="$4"
  local target="${5:-}"
  local output

  if [ -n "$target" ]; then
    output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
      OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$fixture" \
      OMX_WINDOWS_NOTIFY_TARGET_TAB="$target" \
      bash "$repo_dir/src/windows-notify.sh" "test:$label" body session "$HOME")"
  else
    output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
      OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$fixture" \
      bash "$repo_dir/src/windows-notify.sh" "test:$label" body session "$HOME")"
  fi

  assert_decision "$output" "$expected_action" "$expected_reason" "$label"
}

run_runtime_case() {
  local label="$1"
  local expected_action="$2"
  local expected_reason="$3"
  local fixture="$4"
  local identities="$5"
  local output

  output="$(WT_SESSION=fixture-session \
    OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
    OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0 \
    OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$fixture" \
    OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH="$identities" \
    bash "$repo_dir/src/windows-notify.sh" "test:$label" body session "$HOME")"

  assert_decision "$output" "$expected_action" "$expected_reason" "$label"
}

run_case_without_generated_marker() {
  local label="$1"
  local expected_action="$2"
  local expected_reason="$3"
  local fixture="$4"
  local output

  output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
    OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0 \
    OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$fixture" \
    bash "$repo_dir/src/windows-notify.sh" "test:$label" body session "$HOME")"

  assert_decision "$output" "$expected_action" "$expected_reason" "$label"
}

run_case non-terminal notify foreground_not_terminal "$tmpdir/nonterminal.json"
run_runtime_case runtime-same suppress same_terminal_tab_runtime_id "$tmpdir/terminal.json" "$tmpdir/runtime-identities.json"
run_runtime_case runtime-mismatch notify terminal_tab_runtime_id_mismatch "$tmpdir/terminal_same_name_other_runtime.json" "$tmpdir/runtime-identities.json"
run_runtime_case runtime-stale-fallback notify no_strong_target_key "$tmpdir/terminal.json" "$tmpdir/stale-runtime-identities.json"
run_case different-tab notify terminal_tab_mismatch "$tmpdir/terminal.json" tab-b
run_case same-tab suppress same_terminal_tab "$tmpdir/terminal.json" tab-a
run_case marker-mismatch notify terminal_tab_mismatch "$tmpdir/terminal.json" omx-notify-marker-not-selected
run_case_without_generated_marker no-strong-key notify no_strong_target_key "$tmpdir/terminal.json"

cat > "$tmpdir/history.jsonl" <<'JSONL'
{"session_id":"other-session","ts":1,"text":"wrong other session prompt"}
{"session_id":"history-session","ts":2,"text":"right session prompt should be selected and truncated"}
JSONL

output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
  OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0 \
  OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$tmpdir/nonterminal.json" \
  OMX_WINDOWS_NOTIFY_HISTORY_PATH="$tmpdir/history.jsonl" \
  bash "$repo_dir/src/windows-notify.sh" stop hook-body "" "$HOME")"
node -e '
  const rec = JSON.parse(process.argv[1]);
  if (rec.body !== "hook-body") {
    console.error(`FAIL no-session-body-fallback: ${rec.body}`);
    process.exit(1);
  }
  console.log("PASS no-session-body-fallback");
' "$output"

output="$(printf '%s' '{"session_id":"history-session"}' | env \
  OMX_WINDOWS_NOTIFY_NO_NOTIFY=1 \
  OMX_WINDOWS_NOTIFY_USE_TITLE_MARKER=0 \
  OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$tmpdir/nonterminal.json" \
  OMX_WINDOWS_NOTIFY_HISTORY_PATH="$tmpdir/history.jsonl" \
  OMX_WINDOWS_NOTIFY_BODY_MAX_CHARS=22 \
  bash "$repo_dir/src/windows-notify.sh" stop hook-body "" "$HOME")"
node -e '
  const rec = JSON.parse(process.argv[1]);
  if (!rec.body.startsWith("right session prompt") || !rec.body.endsWith("…")) {
    console.error(`FAIL stdin-session-body: ${rec.body}`);
    process.exit(1);
  }
  console.log("PASS stdin-session-body");
' "$output"


output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1   OMX_WINDOWS_NOTIFY_FOCUS_AWARE=0   OMX_WINDOWS_NOTIFY_SOURCE=Codex   OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$tmpdir/nonterminal.json"   bash "$repo_dir/src/windows-notify.sh" stop body session "$HOME")"
node -e '
  const rec = JSON.parse(process.argv[1]);
  if (rec.title !== "[Codex] Task Complete") {
    console.error(`FAIL codex-title-prefix: ${rec.title}`);
    process.exit(1);
  }
  console.log("PASS codex-title-prefix");
' "$output"

output="$(OMX_WINDOWS_NOTIFY_NO_NOTIFY=1   OMX_WINDOWS_NOTIFY_FOCUS_AWARE=0   OMX_WINDOWS_NOTIFY_SOURCE=OMX   OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON="$tmpdir/nonterminal.json"   bash "$repo_dir/src/windows-notify.sh" stop body session "$HOME")"
node -e '
  const rec = JSON.parse(process.argv[1]);
  if (rec.title !== "[OMX] Task Complete") {
    console.error(`FAIL omx-title-prefix: ${rec.title}`);
    process.exit(1);
  }
  console.log("PASS omx-title-prefix");
' "$output"
