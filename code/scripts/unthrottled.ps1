# Run a program with Windows power throttling (EcoQoS / "efficiency mode") disabled for that
# process only, as for a foreground application. Background processes on Windows 11 laptops are
# otherwise scheduled on efficiency cores at low clock, which slows proving by up to 10x.
#   powershell -File scripts/unthrottled.ps1 <exe> <arg1> <arg2> ...
param([Parameter(Mandatory)] [string]$Exe, [Parameter(ValueFromRemainingArguments)] [string[]]$Rest)

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class PowerThrottle {
  [StructLayout(LayoutKind.Sequential)] public struct State { public uint Version; public uint ControlMask; public uint StateMask; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr h, int cls, ref State s, int size);
  // ProcessPowerThrottling = 4; PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 1; StateMask 0 = never throttle
  public static bool Disable(IntPtr h) { var s = new State { Version = 1, ControlMask = 1, StateMask = 0 }; return SetProcessInformation(h, 4, ref s, Marshal.SizeOf(s)); }
}
"@

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.Arguments = ($Rest | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$psi.UseShellExecute = $false
$psi.WorkingDirectory = (Get-Location).Path
$p = [System.Diagnostics.Process]::Start($psi)
if (-not [PowerThrottle]::Disable($p.Handle)) { Write-Warning "could not disable power throttling" }
$p.WaitForExit()
exit $p.ExitCode
