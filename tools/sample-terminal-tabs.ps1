param(
  [int]$Samples = 1,
  [int]$IntervalMs = 300,
  [switch]$IncludeAllDescendants
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class TerminalTabProbeNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

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

function ConvertTo-PlainString([object]$value) {
  if ($null -eq $value) { return '' }
  return [string]$value
}

function Get-WindowTitle([IntPtr]$handle) {
  $length = [TerminalTabProbeNative]::GetWindowTextLength($handle)
  $builder = New-Object System.Text.StringBuilder ([Math]::Max($length + 1, 256))
  [void][TerminalTabProbeNative]::GetWindowText($handle, $builder, $builder.Capacity)
  $builder.ToString()
}

function Get-WindowClass([IntPtr]$handle) {
  $builder = New-Object System.Text.StringBuilder 256
  [void][TerminalTabProbeNative]::GetClassName($handle, $builder, $builder.Capacity)
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

function Get-ControlTypeName([object]$element) {
  try { return ConvertTo-PlainString $element.Current.ControlType.ProgrammaticName } catch { return '' }
}

function Get-NativeWindowHandleValue([object]$element) {
  try { return [int64]$element.Current.NativeWindowHandle } catch { return 0 }
}

function Get-ElementProcessId([object]$element) {
  try { return [int]$element.Current.ProcessId } catch { return 0 }
}

function Convert-ElementToRecord([object]$element, [Nullable[bool]]$isSelected) {
  [ordered]@{
    name = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'Name')
    runtimeId = Get-RuntimeId $element
    automationId = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'AutomationId')
    className = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'ClassName')
    frameworkId = ConvertTo-PlainString (Get-SafeCurrentProperty $element 'FrameworkId')
    controlType = Get-ControlTypeName $element
    nativeWindowHandle = Get-NativeWindowHandleValue $element
    processId = Get-ElementProcessId $element
    rect = Get-BoundingRectangleText $element
    isSelected = if ($null -eq $isSelected) { $null } else { [bool]$isSelected }
  }
}

function Test-IsWindowsTerminalWindow([string]$processName, [string]$processPath, [string]$windowClass) {
  $p = (ConvertTo-PlainString $processName).ToLowerInvariant()
  $path = (ConvertTo-PlainString $processPath).ToLowerInvariant()
  $cls = (ConvertTo-PlainString $windowClass).ToLowerInvariant()
  return ($p -eq 'windowsterminal' -or $p -eq 'wt' -or $path -like '*windowsterminal*' -or $cls -like '*cascadia*')
}

function Get-TopLevelWindows {
  $handles = New-Object System.Collections.Generic.List[IntPtr]
  $callback = [TerminalTabProbeNative+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if ([TerminalTabProbeNative]::IsWindowVisible($hWnd)) { $handles.Add($hWnd) }
    return $true
  }
  [void][TerminalTabProbeNative]::EnumWindows($callback, [IntPtr]::Zero)
  return @($handles)
}

function Get-TerminalWindowTabInfo([IntPtr]$handle) {
  [uint32]$windowProcessId = 0
  [void][TerminalTabProbeNative]::GetWindowThreadProcessId($handle, [ref]$windowProcessId)

  $processName = ''
  $processPath = ''
  if ($windowProcessId -gt 0) {
    try {
      $process = Get-Process -Id $windowProcessId -ErrorAction Stop
      $processName = $process.ProcessName
      try { $processPath = $process.Path } catch { $processPath = '' }
    } catch {
      $processName = "pid:$windowProcessId"
    }
  }

  $windowClass = Get-WindowClass $handle
  if (-not (Test-IsWindowsTerminalWindow $processName $processPath $windowClass)) { return $null }

  $errors = @()
  $tabs = @()
  $rootRecord = $null
  if (-not $uiAutomationAvailable) {
    $errors += 'ui_automation_unavailable'
  } else {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
      if ($null -ne $root) {
        $rootRecord = Convert-ElementToRecord $root $null
        $tabCondition = New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::TabItem
        )
        foreach ($tab in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)) {
          $selected = $false
          try {
            $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $selected = [bool]$pattern.Current.IsSelected
          } catch {}
          $tabs += (Convert-ElementToRecord $tab $selected)
        }
      }
    } catch {
      $errors += "uia_failed:$($_.Exception.Message)"
    }
  }

  $selectedTabs = @($tabs | Where-Object { $_.isSelected })
  [ordered]@{
    handle = $handle.ToInt64()
    processId = [int]$windowProcessId
    processName = $processName
    processPath = $processPath
    title = Get-WindowTitle $handle
    windowClass = $windowClass
    root = $rootRecord
    tabCount = @($tabs).Count
    selectedTabCount = @($selectedTabs).Count
    selectedTabs = @($selectedTabs)
    tabs = @($tabs)
    errors = @($errors)
  }
}

function Get-TerminalSnapshot {
  $windows = @()
  foreach ($handle in Get-TopLevelWindows) {
    $info = Get-TerminalWindowTabInfo $handle
    if ($null -ne $info) { $windows += $info }
  }

  [ordered]@{
    timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    uiAutomationAvailable = $uiAutomationAvailable
    windows = @($windows)
  }
}

$records = @()
for ($i = 0; $i -lt [Math]::Max($Samples, 1); $i++) {
  $records += (Get-TerminalSnapshot)
  if ($i -lt $Samples - 1) { Start-Sleep -Milliseconds $IntervalMs }
}

[ordered]@{
  samples = @($records)
} | ConvertTo-Json -Depth 10
