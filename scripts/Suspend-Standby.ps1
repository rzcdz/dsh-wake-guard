# Suspend-Standby.ps1
#
# Put the machine into Modern Standby (S0 low-power idle), NOT hibernation.
#
# Why not SetSuspendState:
#   On systems that support Modern Standby, SetSuspendState() no longer puts the
#   machine into S0ix. Depending on configuration it either fails with
#   ERROR_NOT_SUPPORTED or falls through to S4 hibernation: the session is
#   written to hiberfil.sys, power is cut, and the next press of the power
#   button brings up the firmware logo. That path cannot be woken by a key press,
#   so it defeats the purpose here.
#
#   Measured on this machine: this system has no S1/S2/S3 (`powercfg /a`), and the
#   Event Log shows sleeps with `Sleep Reason: Application API` landing on event
#   42 (`entering sleep` = S4), while idle-driven Modern Standby shows event 506
#   (`entering Modern Standby`) that a key press exits with event 507
#   (`Reason: Input Keyboard`). Only the 506 path is wakeable by an ordinary key.
#
# The route that actually works, measured on this machine:
#
#   1. Turning the display off alone is not enough. Windows only enters S0ix
#      when the display-off state lasts until the *sleep* idle timeout expires,
#      and this machine ships with `standby-timeout-ac = 0` (never). Turning the
#      display off then left the machine awake with a dark screen — the exact
#      symptom that made the first version look broken.
#   2. With `standby-timeout-ac` temporarily set to 60, the same display-off
#      entered S0ix 2 s later (event 506, `Reason: SC_MONITORPOWER`), and a key
#      press woke it (event 507, `Reason: Input Keyboard`).
#
# So this script temporarily lowers the AC sleep timeout, turns the display off,
# waits for the transition, then restores the original timeout. `powercfg
# /change` works without elevation for the current user's own scheme, which is
# what makes this possible at all.
#
# Restoration matters: the script waits until the machine is actually in S0ix
# (events 506) before putting the old value back, and also restores it on any
# early exit. If the machine never sleeps, the timeout is restored after the
# wait and the script reports that the sleep did not happen.
#
# The virtual sleep key (VK_SLEEP) stays off by default: on a machine without S3
# the power manager may resolve that request to S4. `-IncludeSleepKey` opts in.

param(
    [string]$LogFile = "$env:LOCALAPPDATA\dsh-wake-guard.log",
    [switch]$IncludeSleepKey,
    # Seconds the relaxed sleep timeout waits before Modern Standby engages.
    [int]$SleepTimeoutSec = 20,
    # How long to wait for the 506 before giving up and restoring settings.
    [int]$ConfirmSeconds = 45
)

function Write-Log([string]$message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

# Read the AC standby timeout in seconds, without depending on powercfg's UI
# language: `powercfg /q` prints localized labels, so matching the Chinese or
# English wording breaks on another machine, or on this one when the console
# code page differs from the script file's encoding (which is exactly how the
# first version logged "unknown").
#
# `powercfg /q` prints five hex values: min, max, increment, AC, DC. The AC
# timeout is second from the end. (Reading "two of the five" instead picks up
# the increment, which is 1.)
function Get-AcSleepTimeout {
    try {
        $lines = & "$env:SystemRoot\System32\powercfg.exe" /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
        $hex = @()
        foreach ($line in $lines) {
            if ($line -match '0x([0-9a-fA-F]{8})') { $hex += [Convert]::ToInt32($Matches[1], 16) }
        }
        if ($hex.Count -ge 2) {
            return [int]$hex[$hex.Count - 2]
        }
    } catch { }
    return $null
}

# Apply an AC standby timeout. Seconds in, because that is what /q reports and
# what the comparison above uses — but `powercfg /change` takes MINUTES, so the
# conversion happens here and nowhere else. Passing seconds straight through is
# how a 20-second relax became a 20-minute one (1200 s) during development.
#
# 0 means "never" and must stay 0 when restoring: clamping it to 1 minute would
# silently turn the user's "never sleep" setting into "sleep after 1 minute".
function Set-AcSleepTimeout([int]$seconds) {
    if ($seconds -le 0) {
        & "$env:SystemRoot\System32\powercfg.exe" /change standby-timeout-ac 0 2>$null
        return 0
    }
    $minutes = [Math]::Max(1, [int][Math]::Ceiling($seconds / 60))
    & "$env:SystemRoot\System32\powercfg.exe" /change standby-timeout-ac $minutes 2>$null
    return $minutes
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public class WgPower {
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type; public KEYBDINPUT ki; public int pad1; public int pad2;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public const uint INPUT_KEYBOARD  = 1;
    public const ushort VK_SLEEP      = 0x5F;
    public const int WM_SYSCOMMAND    = 0x0112;
    public const int SC_MONITORPOWER  = 0xF170;
    public const int MONITOR_OFF      = 2;
    public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

    // Press and release the virtual Sleep key.
    public static uint TapSleepKey() {
        INPUT[] down = new INPUT[1];
        down[0].type = INPUT_KEYBOARD;
        down[0].ki.wVk = VK_SLEEP;
        down[0].ki.dwFlags = 0;
        uint a = SendInput(1, down, Marshal.SizeOf(typeof(INPUT)));

        INPUT[] up = new INPUT[1];
        up[0].type = INPUT_KEYBOARD;
        up[0].ki.wVk = VK_SLEEP;
        up[0].ki.dwFlags = 0x0002;
        uint b = SendInput(1, up, Marshal.SizeOf(typeof(INPUT)));
        return a + b;
    }

    // Turning the display off is what the power manager uses to decide the user
    // is gone; on a Modern Standby system it leads to S0ix within seconds.
    public static void DisplayOff() {
        SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, new IntPtr(SC_MONITORPOWER), new IntPtr(MONITOR_OFF));
    }
}
'@

# Record the machine's own sleep timeout so it can be put back exactly.
$original = Get-AcSleepTimeout
Write-Log ("suspend request: AC standby timeout before = {0}s" -f $(if ($null -eq $original) { 'unknown' } else { $original }))

# Restore helper, used both on the success path and on any early exit.
function Restore-Timeout() {
    if ($null -eq $script:original) {
        Write-Log '  restore skipped: original timeout unknown'
        return
    }
    try {
        $minutes = Set-AcSleepTimeout ([int]$script:original)
        $now = Get-AcSleepTimeout
        Write-Log ("  AC standby timeout restored to {0}s (set {1} min, now {2}s)" -f $script:original, $minutes, $(if ($null -eq $now) { '?' } else { $now }))
    } catch {
        Write-Log ("  restore failed: " + $_.Exception.Message)
    }
}

try {
    # Only shorten the timeout; never lengthen one that is already shorter, so a
    # user who set 5 minutes does not get pushed to a slower sleep.
    $relaxed = [Math]::Max(60, $SleepTimeoutSec)
    if ($null -eq $original -or $original -eq 0 -or $original -gt $relaxed) {
        $minutes = Set-AcSleepTimeout $relaxed
        $check = Get-AcSleepTimeout
        if ($null -ne $check) {
            Write-Log ("  AC standby timeout set to {0} min ({1}s) for this suspend" -f $minutes, $check)
        } else {
            Write-Log '  could not read back the changed timeout'
        }
    } else {
        Write-Log ("  AC standby timeout left at {0}s (already shorter)" -f $original)
        $relaxed = $original
    }

    # Take the event-log marker before turning the display off, so the wait loop
    # only ever credits a transition that this request caused.
    $since = Get-Date

    if ($IncludeSleepKey) {
        Write-Log 'suspend request: trying VK_SLEEP (opted in)'
        $sent = [WgPower]::TapSleepKey()
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log ("  VK_SLEEP tap returned=$sent err=$err")
        # If the power manager honours the key, this process suspends here and
        # the remainder runs on resume.
        Start-Sleep -Seconds 2
    }

    Write-Log 'suspend request: display off (Modern Standby route)'
    [WgPower]::DisplayOff()
    Write-Log '  display off broadcast sent'

    # Wait for the 506. The machine suspends mid-wait on success, so the loop
    # simply resumes after wake, finds its elapsed time, and restores the value.
    $deadline = (Get-Date).AddSeconds($ConfirmSeconds)
    $entered = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        try {
            $evt = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-Kernel-Power'
                Id           = 506
                StartTime    = $since
            } -MaxEvents 1 -ErrorAction Stop
            if ($null -ne $evt) {
                $entered = $true
                Write-Log ("  entered Modern Standby at {0}" -f $evt.TimeCreated.ToString('HH:mm:ss'))
                break
            }
        } catch {
            # No event yet; keep waiting.
        }
    }

    if (-not $entered) {
        Write-Log ("  no Modern Standby within {0}s; the sleep timeout may be too long for this request" -f $ConfirmSeconds)
    }
} finally {
    Restore-Timeout
}
