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
#   (`entering Modern Standby`, `Reason: Idle Timeout`). Only the 506 path is
#   wakeable by an ordinary key press.
#
# The workable route is to turn the display off: the power manager treats that as
# loss of user presence and transitions to S0ix a few seconds later. That is the
# 506 path.
#
# The virtual sleep key (VK_SLEEP) is available but NOT used by default: on a
# machine without S3 the power manager may resolve that request to S4, which is
# exactly the outcome this script exists to avoid. `-IncludeSleepKey` opts in for
# a machine that has confirmed it enters S0ix from that key; never assume it.

param(
    [string]$LogFile = "$env:LOCALAPPDATA\dsh-wake-guard.log",
    [switch]$IncludeSleepKey
)

function Write-Log([string]$message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
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

    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

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

if ($IncludeSleepKey) {
    Write-Log 'suspend request: trying VK_SLEEP (opted in)'
    $sent = [WgPower]::TapSleepKey()
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Log ("  VK_SLEEP tap returned=$sent err=$err")
    # Give the power manager a moment to act. If the machine really enters
    # standby, this process is suspended here and the remainder runs on resume.
    Start-Sleep -Seconds 2
} else {
    Write-Log 'suspend request: display off only (VK_SLEEP skipped by default)'
}

Write-Log 'suspend request: display off (Modern Standby route)'
[WgPower]::DisplayOff()
Write-Log '  display off broadcast sent'
