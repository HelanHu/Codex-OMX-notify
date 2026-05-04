param(
  [string]$WtSession = '',
  [string]$SourceCommand = 'unknown',
  [string]$Tty = '',
  [string]$IdentityPath = '',
  [int]$TtlHours = 24,
  [switch]$Quiet
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($WtSession) -and -not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) { $WtSession = $env:WT_SESSION }
if ([string]::IsNullOrWhiteSpace($Tty) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_TTY)) { $Tty = $env:OMX_WINDOWS_NOTIFY_TTY }
if ([string]::IsNullOrWhiteSpace($IdentityPath) -and -not [string]::IsNullOrWhiteSpace($env:OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH)) { $IdentityPath = $env:OMX_WINDOWS_NOTIFY_TAB_IDENTITIES_PATH }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class NotifyTabIdentityNative {
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
} catch { $uiAutomationAvailable = $false }

function ConvertTo-PlainString([object]$value) {
  if ($null -eq $value) { return '' }
  return [string]$value
}

function Get-DefaultIdentityPath {
  $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
  Join-Path (Join-Path $base 'omx-windows-notify') 'tab-identities.json'
}

function Get-WindowTitle([IntPtr]$handle) {
  $length = [NotifyTabIdentityNative]::GetWindowTextLength($handle)
  $builder = New-Object System.Text.StringBuilder ([Math]::Max($length + 1, 256))
  [void][NotifyTabIdentityNative]::GetWindowText($handle, $builder, $builder.Capacity)
  $builder.ToString()
}

function Get-WindowClass([IntPtr]$handle) {
  $builder = New-Object System.Text.StringBuilder 256
  [void][NotifyTabIdentityNative]::GetClassName($handle, $builder, $builder.Capacity)
  $builder.ToString()
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

function Test-IsWindowsTerminalWindow([string]$processName, [string]$processPath, [string]$windowClass) {
  $p = (ConvertTo-PlainString $processName).ToLowerInvariant()
  $path = (ConvertTo-PlainString $processPath).ToLowerInvariant()
  $cls = (ConvertTo-PlainString $windowClass).ToLowerInvariant()
  return ($p -eq 'windowsterminal' -or $p -eq 'wt' -or $path -like '*windowsterminal*' -or $cls -like '*cascadia*')
}

function Get-SelectedTerminalTab([IntPtr]$handle) {
  $errors = @()
  if (-not $uiAutomationAvailable) { return [pscustomobject]@{ tab = $null; errors = @('ui_automation_unavailable') } }
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if ($null -eq $root) { return [pscustomobject]@{ tab = $null; errors = @('uia_root_missing') } }
    $tabCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem
    )
    foreach ($tab in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)) {
      try {
        $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($pattern.Current.IsSelected) {
          return [pscustomobject]@{
            tab = [pscustomobject]@{
              name = ConvertTo-PlainString (Get-SafeCurrentProperty $tab 'Name')
              runtimeId = Get-RuntimeId $tab
              automationId = ConvertTo-PlainString (Get-SafeCurrentProperty $tab 'AutomationId')
              className = ConvertTo-PlainString (Get-SafeCurrentProperty $tab 'ClassName')
              rect = Get-BoundingRectangleText $tab
            }
            errors = @()
          }
        }
      } catch {}
    }
    return [pscustomobject]@{ tab = $null; errors = @('no_selected_tab') }
  } catch {
    $errors += "uia_failed:$($_.Exception.Message)"
    return [pscustomobject]@{ tab = $null; errors = @($errors) }
  }
}

function Read-IdentityStore([string]$path) {
  if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return [pscustomobject]@{ version = 1; updatedAt = ''; records = [pscustomobject]@{} }
}

function Set-RecordProperty([object]$obj, [string]$name, [object]$value) {
  $existing = $obj.PSObject.Properties[$name]
  if ($null -ne $existing) { $existing.Value = $value }
  else { Add-Member -InputObject $obj -MemberType NoteProperty -Name $name -Value $value }
}

function Prune-ExpiredRecords([object]$records) {
  $now = [DateTimeOffset]::Now
  foreach ($prop in @($records.PSObject.Properties)) {
    $expiresAt = ConvertTo-PlainString $prop.Value.expiresAt
    if ([string]::IsNullOrWhiteSpace($expiresAt)) { continue }
    try {
      if ([DateTimeOffset]::Parse($expiresAt) -lt $now) { $records.PSObject.Properties.Remove($prop.Name) }
    } catch {}
  }
}

$result = [ordered]@{
  action = 'skip'
  reason = ''
  wtSession = $WtSession
  sourceCommand = $SourceCommand
  identityPath = if ([string]::IsNullOrWhiteSpace($IdentityPath)) { Get-DefaultIdentityPath } else { $IdentityPath }
  record = $null
  errors = @()
}

try {
  if ([string]::IsNullOrWhiteSpace($WtSession)) { throw 'missing_wt_session' }

  $handle = [NotifyTabIdentityNative]::GetForegroundWindow()
  if ($handle -eq [IntPtr]::Zero) { throw 'no_foreground_window' }

  [uint32]$windowPid = 0
  [void][NotifyTabIdentityNative]::GetWindowThreadProcessId($handle, [ref]$windowPid)
  $processName = ''
  $processPath = ''
  if ($windowPid -gt 0) {
    try {
      $process = Get-Process -Id $windowPid -ErrorAction Stop
      $processName = $process.ProcessName
      try { $processPath = $process.Path } catch { $processPath = '' }
    } catch { $processName = "pid:$windowPid" }
  }
  $windowClass = Get-WindowClass $handle
  if (-not (Test-IsWindowsTerminalWindow $processName $processPath $windowClass)) { throw 'foreground_not_terminal' }

  $selected = Get-SelectedTerminalTab $handle
  if ($selected.errors.Count -gt 0) { $result.errors = @($selected.errors) }
  if ($null -eq $selected.tab -or [string]::IsNullOrWhiteSpace($selected.tab.runtimeId)) { throw 'selected_runtime_id_unavailable' }

  $now = [DateTimeOffset]::Now
  $record = [ordered]@{
    wtSession = $WtSession
    runtimeId = $selected.tab.runtimeId
    tabName = $selected.tab.name
    tabRect = $selected.tab.rect
    windowHandle = $handle.ToInt64()
    terminalPid = [int]$windowPid
    terminalProcess = $processName
    terminalPath = $processPath
    windowTitle = Get-WindowTitle $handle
    windowClass = $windowClass
    tty = $Tty
    sourceCommand = $SourceCommand
    createdAt = $now.ToString('o')
    updatedAt = $now.ToString('o')
    expiresAt = $now.AddHours([Math]::Max($TtlHours, 1)).ToString('o')
  }

  $path = $result.identityPath
  $store = Read-IdentityStore $path
  if ($null -eq $store.records) { Set-RecordProperty $store 'records' ([pscustomobject]@{}) }
  Prune-ExpiredRecords $store.records

  $previous = $store.records.PSObject.Properties[$WtSession]
  if ($null -ne $previous -and -not [string]::IsNullOrWhiteSpace($previous.Value.createdAt)) {
    $record.createdAt = $previous.Value.createdAt
  }
  Set-RecordProperty $store.records $WtSession ([pscustomobject]$record)
  Set-RecordProperty $store 'version' 1
  Set-RecordProperty $store 'updatedAt' $now.ToString('o')

  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = "$path.tmp.$PID"
  ($store | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $path -Force

  $result.action = 'registered'
  $result.reason = 'selected_terminal_tab_runtime_id'
  $result.record = $record
} catch {
  $result.action = 'skip'
  $result.reason = ConvertTo-PlainString $_.Exception.Message
}

if (-not $Quiet) { [pscustomobject]$result | ConvertTo-Json -Depth 8 -Compress }
if ($result.action -eq 'registered') { exit 0 }
exit 0
