param(
  [string]$Title = 'OMX',
  [string]$Body = 'Task finished',
  [string]$SessionId = '',
  [string]$ProjectPath = '',
  [string]$Sound = 'Windows Notify Calendar.wav',
  [switch]$NoNotify,
  [switch]$DisableFocusAware,
  [string]$TargetTab = '',
  [string]$TargetTabSource = '',
  [string]$LogPath = '',
  [string]$ForegroundFixtureJson = '',
  [string]$TabIdentitiesPath = ''
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($TargetTab) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_TARGET_TAB)) {
  $TargetTab = $env:OMX_WINDOWS_NOTIFY_TARGET_TAB
}
if ([string]::IsNullOrWhiteSpace($TargetTabSource) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_TARGET_TAB_SOURCE)) {
  $TargetTabSource = $env:OMX_WINDOWS_NOTIFY_TARGET_TAB_SOURCE
}
if ([string]::IsNullOrWhiteSpace($TargetTabSource)) {
  $TargetTabSource = 'explicit_target_tab'
}
if ([string]::IsNullOrWhiteSpace($LogPath) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_LOG_PATH)) {
  $LogPath = $env:OMX_WINDOWS_NOTIFY_LOG_PATH
}
if ([string]::IsNullOrWhiteSpace($ForegroundFixtureJson) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON)) {
  $ForegroundFixtureJson = $env:OMX_WINDOWS_NOTIFY_FOREGROUND_FIXTURE_JSON
}
if ([string]::IsNullOrWhiteSpace($TabIdentitiesPath) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH)) {
  $TabIdentitiesPath = $env:OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH
}
if ($env:OMX_WINDOWS_NOTIFY_NO_NOTIFY -match '^(1|true|yes|on)$') {
  $NoNotify = $true
}
if ($env:OMX_WINDOWS_NOTIFY_FOCUS_AWARE -match '^(0|false|no|off)$') {
  $DisableFocusAware = $true
}

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class NotifyActiveWindowNative {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

$uiAutomationAvailable = $false
try {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  $uiAutomationAvailable = $true
} catch {
  $uiAutomationAvailable = $false
}

function Get-DefaultLogPath {
  $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $env:LOCALAPPDATA
  } else {
    Join-Path $env:USERPROFILE 'AppData\Local'
  }
  Join-Path (Join-Path $base 'omx-windows-notify') 'notify-decisions.jsonl'
}

function Get-DefaultTabIdentitiesPath {
  $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $env:LOCALAPPDATA
  } else {
    Join-Path $env:USERPROFILE 'AppData\Local'
  }
  Join-Path (Join-Path $base 'omx-windows-notify') 'tab-identities.json'
}

function ConvertTo-PlainString([object]$value) {
  if ($null -eq $value) { return '' }
  return [string]$value
}

function Normalize-TabText([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return '' }
  $normalized = $text.Trim().ToLowerInvariant()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  return $normalized
}

function Get-SafeCurrentProperty([object]$element, [string]$propertyName) {
  try { return $element.Current.$propertyName } catch { return '' }
}

function Get-RuntimeId([object]$element) {
  try { return (($element.GetRuntimeId()) -join '.') } catch { return '' }
}

function Get-BoundingRectangleText([object]$element) {
  try {
    $r = $element.Current.BoundingRectangle
    return "$([Math]::Round($r.X, 0)),$([Math]::Round($r.Y, 0)),$([Math]::Round($r.Width, 0)),$([Math]::Round($r.Height, 0))"
  } catch { return '' }
}

function Convert-TabElementToRecord([object]$element) {
  [pscustomobject]@{
    name = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'Name')
    runtimeId = Get-RuntimeId $element
    automationId = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'AutomationId')
    className = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'ClassName')
    rect = Get-BoundingRectangleText $element
  }
}

function Get-UiAutomationContext([IntPtr]$handle) {
  $context = [ordered]@{
    rootName = ''
    rootClass = ''
    selectedTabs = @()
    selectedTabRecords = @()
    focusedName = ''
    focusedType = ''
    focusedClass = ''
    errors = @()
  }

  if (-not $uiAutomationAvailable -or $handle -eq [IntPtr]::Zero) {
    if (-not $uiAutomationAvailable) { $context.errors += 'ui_automation_unavailable' }
    return [pscustomobject]$context
  }

  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if ($null -ne $root) {
      $context.rootName = ConvertTo-PlainString (Get-SafeCurrentProperty $root 'Name')
      $context.rootClass = ConvertTo-PlainString (Get-SafeCurrentProperty $root 'ClassName')

      try {
        $tabCondition = New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::TabItem
        )
        $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)
        $selected = New-Object System.Collections.Generic.List[string]
        $selectedRecords = @()
        foreach ($tab in $tabs) {
          try {
            $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($pattern.Current.IsSelected) {
              $record = Convert-TabElementToRecord $tab
              $selectedRecords += $record
              if (-not [string]::IsNullOrWhiteSpace($record.name)) { $selected.Add($record.name) }
            }
          } catch {}
        }
        $context.selectedTabs = @($selected | Select-Object -First 10)
        $context.selectedTabRecords = @($selectedRecords | Select-Object -First 10)
      } catch {
        $context.errors += "selected_tabs_failed:$($_.Exception.Message)"
      }
    }
  } catch {
    $context.errors += "uia_root_failed:$($_.Exception.Message)"
  }

  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -ne $focused) {
      $context.focusedName = ConvertTo-PlainString (Get-SafeCurrentProperty $focused 'Name')
      $focusedType = Get-SafeCurrentProperty $focused 'ControlType'
      $context.focusedType = if ($null -ne $focusedType) { ConvertTo-PlainString $focusedType.ProgrammaticName } else { '' }
      $context.focusedClass = ConvertTo-PlainString (Get-SafeCurrentProperty $focused 'ClassName')
    }
  } catch {
    $context.errors += "focused_element_failed:$($_.Exception.Message)"
  }

  [pscustomobject]$context
}

function Convert-FixtureToForegroundInfo([string]$fixture) {
  $raw = $fixture
  if (Test-Path -LiteralPath $fixture -ErrorAction SilentlyContinue) {
    $raw = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8
  }
  $obj = $raw | ConvertFrom-Json
  $selected = @()
  $selectedRecords = @()
  if ($null -ne $obj.selectedTabRecords) { $selectedRecords = @($obj.selectedTabRecords) }
  elseif ($null -ne $obj.SelectedTabRecords) { $selectedRecords = @($obj.SelectedTabRecords) }

  if ($null -ne $obj.selectedTabs) {
    foreach ($item in @($obj.selectedTabs)) {
      if ($null -ne $item.PSObject.Properties['runtimeId']) {
        $selectedRecords += $item
        if ($null -ne $item.PSObject.Properties['name']) { $selected += (ConvertTo-PlainString $item.name) }
      } else {
        $selected += (ConvertTo-PlainString $item)
      }
    }
  } elseif ($null -ne $obj.SelectedTabs) {
    foreach ($item in @($obj.SelectedTabs)) { $selected += (ConvertTo-PlainString $item) }
  }

  foreach ($record in @($selectedRecords)) {
    if ($null -ne $record.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace($record.name)) {
      if (@($selected | Where-Object { $_ -eq $record.name }).Count -eq 0) { $selected += (ConvertTo-PlainString $record.name) }
    }
  }

  [pscustomobject]@{
    Handle = if ($null -ne $obj.handle) { [int64]$obj.handle } elseif ($null -ne $obj.Handle) { [int64]$obj.Handle } else { 0 }
    ProcessId = if ($null -ne $obj.pid) { [int]$obj.pid } elseif ($null -ne $obj.ProcessId) { [int]$obj.ProcessId } else { 0 }
    ProcessName = if ($obj.process) { [string]$obj.process } elseif ($obj.ProcessName) { [string]$obj.ProcessName } else { '' }
    Title = if ($obj.title) { [string]$obj.title } elseif ($obj.Title) { [string]$obj.Title } else { '' }
    Path = if ($obj.path) { [string]$obj.path } elseif ($obj.Path) { [string]$obj.Path } else { '' }
    WindowClass = if ($obj.windowClass) { [string]$obj.windowClass } elseif ($obj.WindowClass) { [string]$obj.WindowClass } else { '' }
    UiRootName = if ($obj.uiRootName) { [string]$obj.uiRootName } elseif ($obj.UiRootName) { [string]$obj.UiRootName } else { '' }
    UiRootClass = if ($obj.uiRootClass) { [string]$obj.uiRootClass } elseif ($obj.UiRootClass) { [string]$obj.UiRootClass } else { '' }
    SelectedTabs = @($selected)
    SelectedTabRecords = @($selectedRecords)
    FocusedName = if ($obj.focusedName) { [string]$obj.focusedName } elseif ($obj.FocusedName) { [string]$obj.FocusedName } else { '' }
    FocusedType = if ($obj.focusedType) { [string]$obj.focusedType } elseif ($obj.FocusedType) { [string]$obj.FocusedType } else { '' }
    FocusedClass = if ($obj.focusedClass) { [string]$obj.focusedClass } elseif ($obj.FocusedClass) { [string]$obj.FocusedClass } else { '' }
    Errors = @()
    Source = 'fixture'
  }
}

function Get-ForegroundWindowInfo {
  if (-not [string]::IsNullOrWhiteSpace($ForegroundFixtureJson)) {
    return Convert-FixtureToForegroundInfo $ForegroundFixtureJson
  }

  $handle = [NotifyActiveWindowNative]::GetForegroundWindow()
  if ($handle -eq [IntPtr]::Zero) {
    return [pscustomobject]@{ Handle = 0; ProcessId = 0; ProcessName = ''; Title = ''; Path = ''; WindowClass = ''; UiRootName = ''; UiRootClass = ''; SelectedTabs = @(); SelectedTabRecords = @(); FocusedName = ''; FocusedType = ''; FocusedClass = ''; Errors = @('no_foreground_window'); Source = 'live' }
  }

  $length = [NotifyActiveWindowNative]::GetWindowTextLength($handle)
  $titleBuilder = New-Object System.Text.StringBuilder ([Math]::Max($length + 1, 256))
  [void][NotifyActiveWindowNative]::GetWindowText($handle, $titleBuilder, $titleBuilder.Capacity)
  $title = $titleBuilder.ToString()

  $classBuilder = New-Object System.Text.StringBuilder 256
  [void][NotifyActiveWindowNative]::GetClassName($handle, $classBuilder, $classBuilder.Capacity)
  $windowClass = $classBuilder.ToString()

  [uint32]$activeProcessId = 0
  [void][NotifyActiveWindowNative]::GetWindowThreadProcessId($handle, [ref]$activeProcessId)

  $processName = ''
  $processPath = ''
  if ($activeProcessId -gt 0) {
    try {
      $process = Get-Process -Id $activeProcessId -ErrorAction Stop
      $processName = $process.ProcessName
      try { $processPath = $process.Path } catch { $processPath = '' }
    } catch {
      $processName = "pid:$activeProcessId"
    }
  }

  $ui = Get-UiAutomationContext $handle
  [pscustomobject]@{
    Handle = $handle.ToInt64()
    ProcessId = [int]$activeProcessId
    ProcessName = $processName
    Title = $title
    Path = $processPath
    WindowClass = $windowClass
    UiRootName = $ui.rootName
    UiRootClass = $ui.rootClass
    SelectedTabs = @($ui.selectedTabs)
    SelectedTabRecords = @($ui.selectedTabRecords)
    FocusedName = $ui.focusedName
    FocusedType = $ui.focusedType
    FocusedClass = $ui.focusedClass
    Errors = @($ui.errors)
    Source = 'live'
  }
}

function Test-IsWindowsTerminalForeground([object]$info) {
  $process = (ConvertTo-PlainString $info.ProcessName).ToLowerInvariant()
  $path = (ConvertTo-PlainString $info.Path).ToLowerInvariant()
  $windowClass = (ConvertTo-PlainString $info.WindowClass).ToLowerInvariant()
  $uiClass = (ConvertTo-PlainString $info.UiRootClass).ToLowerInvariant()
  return (
    $process -eq 'windowsterminal' -or
    $process -eq 'wt' -or
    $path -like '*windowsterminal*' -or
    $windowClass -like '*cascadia*' -or
    $uiClass -like '*cascadia*'
  )
}

function New-CandidateKey([string]$value, [string]$source, [string]$strength) {
  [pscustomobject]@{
    value = $value
    normalized = Normalize-TabText $value
    source = $source
    strength = $strength
  }
}

function Resolve-TargetKeyCandidates([string]$resolvedTargetTab, [string]$identitySource) {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($resolvedTargetTab)) {
    $candidates += (New-CandidateKey $resolvedTargetTab $identitySource 'strong')
  }

  # These are diagnostic only unless a future identity spike explicitly promotes one.
  foreach ($item in @(
    @{ value = $Title; source = 'title' },
    @{ value = $Body; source = 'body' },
    @{ value = $ProjectPath; source = 'project_path' },
    @{ value = $SessionId; source = 'session_id' },
    @{ value = $env:CODEX_THREAD_ID; source = 'codex_thread_id' },
    @{ value = $env:WT_SESSION; source = 'wt_session' },
    @{ value = $env:TMUX; source = 'tmux' },
    @{ value = $env:TMUX_PANE; source = 'tmux_pane' }
  )) {
    if (-not [string]::IsNullOrWhiteSpace($item.value)) {
      $candidates += (New-CandidateKey ([string]$item.value) ([string]$item.source) 'log_only')
    }
  }
  return @($candidates)
}

function Find-StrongTabMatch([object[]]$selectedTabs, [object[]]$candidates) {
  $strong = @($candidates | Where-Object { $_.strength -eq 'strong' -and -not [string]::IsNullOrWhiteSpace($_.normalized) })
  foreach ($candidate in $strong) {
    foreach ($tab in @($selectedTabs)) {
      $tabText = ConvertTo-PlainString $tab
      $tabNorm = Normalize-TabText $tabText
      if ([string]::IsNullOrWhiteSpace($tabNorm)) { continue }
      if ($tabNorm -eq $candidate.normalized -or $tabNorm.Contains($candidate.normalized) -or $candidate.normalized.Contains($tabNorm)) {
        return [pscustomobject]@{
          candidate = $candidate
          selectedTab = $tabText
          selectedTabNormalized = $tabNorm
        }
      }
    }
  }
  return $null
}

function Get-TabIdentitiesPath {
  if ([string]::IsNullOrWhiteSpace($TabIdentitiesPath)) { return Get-DefaultTabIdentitiesPath }
  return $TabIdentitiesPath
}

function Get-RegisteredTabIdentity([string]$wtSession) {
  $path = Get-TabIdentitiesPath
  $result = [ordered]@{
    status = 'mapping_missing'
    path = $path
    wtSession = $wtSession
    record = $null
    selectedRuntimeIds = @()
    matchedRuntimeId = ''
    errors = @()
  }
  if ([string]::IsNullOrWhiteSpace($wtSession)) { $result.status = 'missing_wt_session'; return [pscustomobject]$result }
  if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { return [pscustomobject]$result }
  try {
    $store = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $store.records) { return [pscustomobject]$result }
    $prop = $store.records.PSObject.Properties[$wtSession]
    if ($null -eq $prop) { return [pscustomobject]$result }
    $record = $prop.Value
    $runtimeId = ConvertTo-PlainString $record.runtimeId
    if ([string]::IsNullOrWhiteSpace($runtimeId)) { $result.status = 'mapping_incomplete'; $result.record = $record; return [pscustomobject]$result }
    $expiresAt = ConvertTo-PlainString $record.expiresAt
    if (-not [string]::IsNullOrWhiteSpace($expiresAt)) {
      try {
        if ([DateTimeOffset]::Parse($expiresAt) -lt [DateTimeOffset]::Now) {
          $result.status = 'mapping_stale'
          $result.record = $record
          return [pscustomobject]$result
        }
      } catch { $result.errors += "expires_parse_failed:$($_.Exception.Message)" }
    }
    $result.status = 'mapping_found'
    $result.record = $record
    return [pscustomobject]$result
  } catch {
    $result.status = 'mapping_read_error'
    $result.errors += $_.Exception.Message
    return [pscustomobject]$result
  }
}

function Get-SelectedRuntimeIds([object]$foreground) {
  $ids = @()
  foreach ($record in @($foreground.SelectedTabRecords)) {
    if ($null -eq $record) { continue }
    $runtimeId = ''
    if ($null -ne $record.PSObject.Properties['runtimeId']) { $runtimeId = ConvertTo-PlainString $record.runtimeId }
    elseif ($null -ne $record.PSObject.Properties['RuntimeId']) { $runtimeId = ConvertTo-PlainString $record.RuntimeId }
    if (-not [string]::IsNullOrWhiteSpace($runtimeId)) { $ids += $runtimeId }
  }
  return @($ids | Select-Object -Unique)
}

function Get-RuntimeIdentityDecision([object]$foreground) {
  $identity = Get-RegisteredTabIdentity (ConvertTo-PlainString $env:WT_SESSION)
  if ($identity.status -ne 'mapping_found') { return $identity }
  $selectedRuntimeIds = @(Get-SelectedRuntimeIds $foreground)
  $identity.selectedRuntimeIds = @($selectedRuntimeIds)
  if ($selectedRuntimeIds.Count -eq 0) { $identity.status = 'selected_runtime_id_unavailable'; return $identity }
  $targetRuntimeId = ConvertTo-PlainString $identity.record.runtimeId
  foreach ($rid in $selectedRuntimeIds) {
    if ($rid -eq $targetRuntimeId) {
      $identity.status = 'same_runtime_id'
      $identity.matchedRuntimeId = $rid
      return $identity
    }
  }
  $identity.status = 'runtime_id_mismatch'
  return $identity
}

function Get-NotifyDecision([object]$foreground, [object[]]$candidates) {
  if ($DisableFocusAware) {
    return [pscustomobject]@{ action = 'notify'; reason = 'focus_aware_disabled'; match = $null; runtimeIdentity = $null }
  }

  $isTerminal = Test-IsWindowsTerminalForeground $foreground
  if (-not $isTerminal) {
    return [pscustomobject]@{ action = 'notify'; reason = 'foreground_not_terminal'; match = $null; runtimeIdentity = $null }
  }

  $runtimeIdentity = Get-RuntimeIdentityDecision $foreground
  if ($runtimeIdentity.status -eq 'same_runtime_id') {
    return [pscustomobject]@{ action = 'suppress'; reason = 'same_terminal_tab_runtime_id'; match = $null; runtimeIdentity = $runtimeIdentity }
  }
  if ($runtimeIdentity.status -eq 'runtime_id_mismatch') {
    return [pscustomobject]@{ action = 'notify'; reason = 'terminal_tab_runtime_id_mismatch'; match = $null; runtimeIdentity = $runtimeIdentity }
  }

  $selected = @($foreground.SelectedTabs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($selected.Count -eq 0) {
    return [pscustomobject]@{ action = 'notify'; reason = 'terminal_tab_unknown'; match = $null; runtimeIdentity = $runtimeIdentity }
  }

  $strong = @($candidates | Where-Object { $_.strength -eq 'strong' -and -not [string]::IsNullOrWhiteSpace($_.normalized) })
  if ($strong.Count -eq 0) {
    return [pscustomobject]@{ action = 'notify'; reason = 'no_strong_target_key'; match = $null; runtimeIdentity = $runtimeIdentity }
  }

  $match = Find-StrongTabMatch $selected $candidates
  if ($null -ne $match) {
    return [pscustomobject]@{ action = 'suppress'; reason = 'same_terminal_tab'; match = $match; runtimeIdentity = $runtimeIdentity }
  }

  return [pscustomobject]@{ action = 'notify'; reason = 'terminal_tab_mismatch'; match = $null; runtimeIdentity = $runtimeIdentity }
}

function Test-IsMarkerIdentitySource([string]$source) {
  return ((ConvertTo-PlainString $source).ToLowerInvariant() -like '*title_marker')
}

function Write-NotifyDecisionLog([object]$record) {
  $path = if ([string]::IsNullOrWhiteSpace($LogPath)) { Get-DefaultLogPath } else { $LogPath }
  try {
    $dir = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($record | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $path -Encoding UTF8
  } catch {
    Write-Error ("decision_log_failed: " + $_.Exception.Message)
  }
}

function Show-Notification {
  param([string]$NotifyTitle, [string]$NotifyBody, [string]$Project, [string]$NotifySound)

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System

  $notify = New-Object System.Windows.Forms.NotifyIcon
  try {
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Visible = $true
    $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::None
    $notify.BalloonTipTitle = $NotifyTitle
    $notify.BalloonTipText = if ($Project) { "$NotifyBody`n$Project" } else { $NotifyBody }

    if (-not [string]::IsNullOrWhiteSpace($NotifySound) -and $NotifySound.ToLowerInvariant() -ne 'none') {
      $soundPath = Join-Path $env:WINDIR "Media\$NotifySound"
      if (Test-Path $soundPath) {
        try {
          $player = New-Object System.Media.SoundPlayer $soundPath
          $player.Play()
        } catch {
          [System.Media.SystemSounds]::Asterisk.Play()
        }
      } else {
        [System.Media.SystemSounds]::Asterisk.Play()
      }
    }

    $notify.ShowBalloonTip(10000)
    Start-Sleep -Seconds 11
  } finally {
    $notify.Dispose()
  }
}

$identitySource = 'none'
$resolvedTargetTab = $TargetTab
$titleMarkerApplied = $false
$titleMarkerError = ''
$originalConsoleTitle = $null
$generatedTitleMarker = ''

try {
  if (-not $DisableFocusAware -and -not [string]::IsNullOrWhiteSpace($resolvedTargetTab)) {
    $identitySource = $TargetTabSource
  }

  $foreground = Get-ForegroundWindowInfo
  $candidates = Resolve-TargetKeyCandidates $resolvedTargetTab $identitySource
  $decision = Get-NotifyDecision $foreground $candidates

  # Terminal title updates can arrive a little later than the WSL/tmux wrapper
  # command returns. For generated title markers only, retry briefly before
  # concluding mismatch. Mismatches still notify; this only catches late strong
  # marker matches for the same active tab.
  if ($decision.reason -eq 'terminal_tab_mismatch' -and (Test-IsMarkerIdentitySource $identitySource)) {
    foreach ($delayMs in @(150, 250, 350, 500)) {
      Start-Sleep -Milliseconds $delayMs
      $retryForeground = Get-ForegroundWindowInfo
      $retryDecision = Get-NotifyDecision $retryForeground $candidates
      if ($retryDecision.action -eq 'suppress') {
        $foreground = $retryForeground
        $decision = $retryDecision
        break
      }
    }
  }
} catch {
  $foreground = [pscustomobject]@{ Handle = 0; ProcessId = 0; ProcessName = ''; Title = ''; Path = ''; WindowClass = ''; UiRootName = ''; UiRootClass = ''; SelectedTabs = @(); SelectedTabRecords = @(); FocusedName = ''; FocusedType = ''; FocusedClass = ''; Errors = @("decision_failed:$($_.Exception.Message)"); Source = 'error' }
  $candidates = Resolve-TargetKeyCandidates $resolvedTargetTab $identitySource
  $decision = [pscustomobject]@{ action = 'notify'; reason = 'decision_error'; match = $null; runtimeIdentity = $null }
}

$matchingKey = $null
if ($null -ne $decision.match) {
  $matchingKey = [ordered]@{
    candidateValue = $decision.match.candidate.value
    candidateSource = $decision.match.candidate.source
    selectedTab = $decision.match.selectedTab
  }
}

$record = [ordered]@{
  timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  action = $decision.action
  reason = $decision.reason
  title = $Title
  body = $Body
  sessionId = $SessionId
  projectPath = $ProjectPath
  sound = $Sound
  focusAware = (-not $DisableFocusAware)
  noNotify = [bool]$NoNotify
  identity = [ordered]@{
    source = $identitySource
    resolvedTargetTab = $resolvedTargetTab
    generatedTitleMarker = $generatedTitleMarker
    titleMarkerApplied = $titleMarkerApplied
    titleMarkerError = $titleMarkerError
    originalConsoleTitle = $originalConsoleTitle
  }
  foreground = [ordered]@{
    source = $foreground.Source
    process = $foreground.ProcessName
    pid = $foreground.ProcessId
    path = $foreground.Path
    title = $foreground.Title
    handle = $foreground.Handle
    windowClass = $foreground.WindowClass
    uiRootName = $foreground.UiRootName
    uiRootClass = $foreground.UiRootClass
    selectedTabs = @($foreground.SelectedTabs)
    selectedTabRecords = @($foreground.SelectedTabRecords)
    focusedName = $foreground.FocusedName
    focusedType = $foreground.FocusedType
    focusedClass = $foreground.FocusedClass
    isWindowsTerminal = (Test-IsWindowsTerminalForeground $foreground)
    errors = @($foreground.Errors)
  }
  targetCandidates = @($candidates)
  runtimeIdentity = $decision.runtimeIdentity
  matchingKey = $matchingKey
}

Write-NotifyDecisionLog $record

if ($NoNotify) {
  $record | ConvertTo-Json -Depth 8 -Compress
}

if ($decision.action -eq 'notify' -and -not $NoNotify) {
  Show-Notification -NotifyTitle $Title -NotifyBody $Body -Project $ProjectPath -NotifySound $Sound
}
