param(
  [int64]$WindowHandle = 0,
  [int]$DelayMs = 250
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class TerminalTabRoundTripNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

function S([object]$v){ if($null -eq $v){''}else{[string]$v} }
function Rid($e){ try{($e.GetRuntimeId() -join '.')}catch{''} }
function Name($e){ try{S $e.Current.Name}catch{''} }
function RectText($e){ try{$r=$e.Current.BoundingRectangle; "$([math]::Round($r.X,0)),$([math]::Round($r.Y,0)),$([math]::Round($r.Width,0)),$([math]::Round($r.Height,0))"}catch{''} }
function WinTitle([IntPtr]$h){ $b=New-Object System.Text.StringBuilder 512; [void][TerminalTabRoundTripNative]::GetWindowText($h,$b,512); $b.ToString() }
function WinClass([IntPtr]$h){ $b=New-Object System.Text.StringBuilder 256; [void][TerminalTabRoundTripNative]::GetClassName($h,$b,256); $b.ToString() }
function WinPid([IntPtr]$h){ [uint32]$procId=0; [void][TerminalTabRoundTripNative]::GetWindowThreadProcessId($h,[ref]$procId); [int]$procId }
function IsTerminal([IntPtr]$h){
  $processId=WinPid $h; $p=$null; try{$p=Get-Process -Id $processId -ErrorAction Stop}catch{}
  $pn=if($p){$p.ProcessName.ToLowerInvariant()}else{''}; $path=''; if($p){try{$path=$p.Path.ToLowerInvariant()}catch{}}
  $cls=(WinClass $h).ToLowerInvariant()
  $pn -eq 'windowsterminal' -or $pn -eq 'wt' -or $path -like '*windowsterminal*' -or $cls -like '*cascadia*'
}
function GetHandles(){
  $list=New-Object System.Collections.Generic.List[IntPtr]
  $cb=[TerminalTabRoundTripNative+EnumWindowsProc]{ param([IntPtr]$h,[IntPtr]$l) if([TerminalTabRoundTripNative]::IsWindowVisible($h)){ $list.Add($h) }; $true }
  [void][TerminalTabRoundTripNative]::EnumWindows($cb,[IntPtr]::Zero)
  @($list)
}
function GetTabs([IntPtr]$h){
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($h)
  $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::TabItem)
  $tabs=@()
  foreach($tab in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$cond)){
    $selected=$false; try{$selected=$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected}catch{}
    $tabs += [pscustomobject]@{ element=$tab; name=Name $tab; runtimeId=Rid $tab; rect=RectText $tab; isSelected=[bool]$selected }
  }
  @($tabs)
}
function PublicTab($t){ [ordered]@{ name=$t.name; runtimeId=$t.runtimeId; rect=$t.rect; isSelected=$t.isSelected } }
function SelectTab($t){ $p=$t.element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern); $p.Select() }

$target=[IntPtr]::Zero
if($WindowHandle -ne 0){ $target=[IntPtr]$WindowHandle }
else{
  foreach($h in GetHandles){
    if(-not (IsTerminal $h)){ continue }
    $tabs=GetTabs $h
    $visibleTabs=@($tabs | Where-Object { $_.rect -notlike '-*' -and $_.rect -notlike 'Infinity*' })
    if($visibleTabs.Count -gt 1){ $target=$h; break }
  }
}
if($target -eq [IntPtr]::Zero){ throw 'no_terminal_window_with_multiple_tabs' }

$initialTabs=GetTabs $target
$initialSelected=@($initialTabs | Where-Object {$_.isSelected} | Select-Object -First 1)
if($initialSelected.Count -eq 0){ throw 'no_initial_selected_tab' }
$initial=$initialSelected[0]
$steps=@()
try{
  foreach($tab in $initialTabs){
    SelectTab $tab
    Start-Sleep -Milliseconds $DelayMs
    $afterTabs=GetTabs $target
    $selected=@($afterTabs | Where-Object {$_.isSelected} | Select-Object -First 1)
    $steps += [ordered]@{
      requested = PublicTab $tab
      selectedAfter = if($selected.Count){ PublicTab $selected[0] } else { $null }
      matchedRequestedRuntimeId = if($selected.Count){ $selected[0].runtimeId -eq $tab.runtimeId } else { $false }
    }
  }
} finally {
  try { SelectTab $initial } catch {}
  Start-Sleep -Milliseconds $DelayMs
}
$restoredTabs=GetTabs $target
$restored=@($restoredTabs | Where-Object {$_.isSelected} | Select-Object -First 1)
[ordered]@{
  window = [ordered]@{ handle=$target.ToInt64(); pid=WinPid $target; title=WinTitle $target; class=WinClass $target }
  initialSelected = PublicTab $initial
  steps = @($steps)
  restoredSelected = if($restored.Count){ PublicTab $restored[0] } else { $null }
  restoredOriginalRuntimeId = if($restored.Count){ $restored[0].runtimeId -eq $initial.runtimeId } else { $false }
} | ConvertTo-Json -Depth 8
