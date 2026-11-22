# WakeGuard.ps1
#
# Detects resume-from-sleep, then for a grace period simulates real keyboard
# activity so Windows keeps considering the user present.
#
# Deliberately ungated: any detected resume (clock jump or Kernel-Power 507/105)
# arms and continuously extends the grace period. That keeps the machine awake
# and reachable, at the cost of the screen cycling on while nobody is using it.
# Enable this plugin before sleeping, disable it after waking, to stop the cycle.
#
# The key used is VK_F15 (0x7E). F15 exists in the HID keyboard usage table but
# is absent from virtually every physical keyboard, so pressing it has no visible
# effect on any application.

param(
    [int]$GraceMinutes = 10,
    [int]$PollMs = 500,
    [double]$JumpThresholdSec = 2.0,
    [int]$PressEverySec = 20,
    [int]$RetentionDays = 1,
    [string]$LogFile = "$env:LOCALAPPDATA\dsh-wake-guard.log"
)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WakeKey {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

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

    public const uint ES_CONTINUOUS      = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint INPUT_KEYBOARD     = 1;
    public const ushort VK_F15           = 0x7E;
    public const uint KEYEVENTF_KEYUP    = 0x0002;

    public static uint TapF15() {
        INPUT[] d = new INPUT[1];
        d[0].type = INPUT_KEYBOARD; d[0].ki.wVk = VK_F15; d[0].ki.dwFlags = 0;
        uint a = SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
        INPUT[] u = new INPUT[1];
        u[0].type = INPUT_KEYBOARD; u[0].ki.wVk = VK_F15; u[0].ki.dwFlags = KEYEVENTF_KEYUP;
        uint b = SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
        return a + b;
    }
}
'@

function Write-Log([string]$message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

# Keep only the last day of log lines.
#
# Runs in two situations: once when the helper starts, and then whenever the
# clock has advanced past the next prune time so a long-running helper does not
# grow the file without bound. Lines carry a leading "yyyy-MM-dd HH:mm:ss", which
# is what the cutoff compares against; lines that do not parse are dropped.
function Invoke-LogPrune {
    try {
        if (-not (Test-Path $LogFile)) { return }
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        $kept = New-Object System.Collections.Generic.List[string]

        foreach ($raw in [System.IO.File]::ReadLines($LogFile)) {
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $stamp = $null
            if ($raw.Length -ge 19) {
                $parsed = [DateTime]::MinValue
                if ([DateTime]::TryParseExact(
                        $raw.Substring(0, 19),
                        'yyyy-MM-dd HH:mm:ss',
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None,
                        [ref]$parsed)) {
                    $stamp = $parsed
                }
            }
            if ($null -ne $stamp -and $stamp -lt $cutoff) { continue }
            $kept.Add($raw)
        }

        # Only rewrite when something was actually dropped.
        $original = @([System.IO.File]::ReadLines($LogFile)).Count
        if ($kept.Count -lt $original) {
            $tmp = "$LogFile.tmp"
            [System.IO.File]::WriteAllLines($tmp, $kept)
            Move-Item -LiteralPath $tmp -Destination $LogFile -Force
        }
    } catch {
        # Pruning must never break the guard loop.
    }
}

# Uses the event log to catch resumes that a short clock jump might miss.
function Test-RecentWake([int]$withinSeconds) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = 507, 105
            StartTime    = (Get-Date).AddSeconds(-$withinSeconds)
        } -MaxEvents 1 -ErrorAction Stop
        return ($null -ne $events)
    } catch {
        return $false
    }
}

Write-Log "start pid=$PID grace=${GraceMinutes}min poll=${PollMs}ms pressEvery=${PressEverySec}s mode=f15-tap"

$holdUntil = [DateTime]::MinValue
$active = $false
$lastPress = [DateTime]::MinValue
$pressCount = 0

# Prune once at startup so a stale file from a previous run is trimmed straight
# away, then no more often than hourly.
Invoke-LogPrune
$nextPrune = (Get-Date).AddHours(1)

while ($true) {
    $t0 = [DateTime]::UtcNow
    Start-Sleep -Milliseconds $PollMs
    $t1 = [DateTime]::UtcNow
    $elapsed = ($t1 - $t0).TotalSeconds

    $nowLocal = Get-Date
    if ($nowLocal -ge $nextPrune) {
        Invoke-LogPrune
        $nextPrune = $nowLocal.AddHours(1)
    }

    $woke = $false
    $reason = ''

    if ($elapsed -gt $JumpThresholdSec) {
        $woke = $true
        $reason = "clock jump {0:N1}s" -f $elapsed
    }
    elseif (-not $active) {
        # Only consult the event log while idle, so a long grace window does not
        # turn into a stream of lookups.
        if (Test-RecentWake -withinSeconds 5) {
            $woke = $true
            $reason = 'event log 507/105'
        }
    }

    if ($woke) {
        $holdUntil = $t1.AddMinutes($GraceMinutes)
        Write-Log ("wake detected ({0}) active until {1}" -f $reason, $holdUntil.ToLocalTime().ToString('HH:mm:ss'))
        if (-not $active) {
            $active = $true
            $pressCount = 0
            $null = [WakeKey]::SetThreadExecutionState(
                [WakeKey]::ES_CONTINUOUS -bor [WakeKey]::ES_SYSTEM_REQUIRED)
            # Press immediately: the first seconds decide whether it re-sleeps.
            $r = [WakeKey]::TapF15()
            $lastPress = $t1
            $pressCount = 1
            Write-Log "power request acquired + first F15 tap ret=$r"
        }
    }

    if ($active) {
        if ($t1 -lt $holdUntil) {
            $null = [WakeKey]::SetThreadExecutionState(
                [WakeKey]::ES_CONTINUOUS -bor [WakeKey]::ES_SYSTEM_REQUIRED)

            if (($t1 - $lastPress).TotalSeconds -ge $PressEverySec) {
                $r = [WakeKey]::TapF15()
                $lastPress = $t1
                $pressCount = $pressCount + 1
                if (($pressCount % 5) -eq 0) {
                    Write-Log "  F15 taps=$pressCount ret=$r"
                }
            }
        } else {
            $null = [WakeKey]::SetThreadExecutionState([WakeKey]::ES_CONTINUOUS)
            $active = $false
            Write-Log "grace expired after $pressCount taps, released"
        }
    }
}
