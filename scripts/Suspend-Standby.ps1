# Suspend-Standby.ps1
#
# Put the machine into Modern Standby (S0 low-power idle), NOT hibernation.
#
# Why not SetSuspendState:
#   On systems that support Modern Standby, SetSuspendState() no longer puts the
#   machine into S0ix. Depending on configuration it either fails with
#   ERROR_NOT_SUPPORTED or, as observed on this machine, falls through to S4
#   hibernation: the session is written to hiberfil.sys, power is cut, and the
#   next press of the power button brings up the firmware logo. That path cannot
#   be woken by an AC power change, so it defeats the purpose here.
#
#   This is documented in the Windows driver community: user-mode code can no
#   longer suspend a Modern Standby machine through SetSuspendState; the
#   workable route is to turn the display off, which the power manager treats as
#   loss of user presence and then transitions to S0ix a few seconds later.
#
# Two steps, in order:
#   1. Try the virtual sleep key (VK_SLEEP). The power manager treats this as the
#      sleep button, which enters Modern Standby directly when honoured.
#   2. Turn the display off via SC_MONITORPOWER. This is the documented fallback
#      and works from an interactive session.
#
# The second step runs regardless, because a display that is already off simply
# stays off, and the power manager needs the display-off state either way.

param(
    [string]$LogFile = "$env:LOCALAPPDATA\dsh-wake-guard.log"
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

Write-Log 'suspend request: trying VK_SLEEP'

$sent = [WgPower]::TapSleepKey()
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Write-Log ("  VK_SLEEP tap returned=$sent err=$err")

# Give the power manager a moment to act on the sleep key. If the machine really
# enters standby the process is suspended here and the remainder runs on resume,
# where turning the display off again is harmless.
Start-Sleep -Seconds 2

Write-Log 'suspend request: display off (Modern Standby route)'
[WgPower]::DisplayOff()
Write-Log '  display off broadcast sent'
