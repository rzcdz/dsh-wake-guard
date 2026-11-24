# Restart-DSH.ps1
#
# Relaunches the DSH desktop app after this process exits.
#
# The plugin's Host half normally restarts through Electron's own
# `app.relaunch()`. This script is the fallback for a Host that cannot reach
# the Electron main process: it is spawned detached, waits for the plugin's
# HTTP reply to flush, stops every DSH process, waits until the single-instance
# lock is actually released, then starts the executable again.
#
# Why the wait loop matters: Electron's single-instance lock makes a new
# process hand its request to the running one and exit. Starting the
# replacement before the old processes are really gone would therefore leave
# nothing running — the exact failure this script exists to avoid.

param(
    [string]$ProcessName = 'DSH NEXT',
    [Parameter(Mandatory = $true)][string]$Executable,
    [string]$WorkingDirectory = '',
    [int]$DelayMs = 1200,
    [int]$WaitSeconds = 20
)

function Write-Note([string]$message) {
    try {
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
        $log = Join-Path $env:LOCALAPPDATA 'dsh-wake-guard-restart.log'
        Add-Content -Path $log -Value $line -Encoding UTF8
    } catch { }
}

if (-not (Test-Path -LiteralPath $Executable)) {
    Write-Note "abort: executable not found: $Executable"
    exit 1
}

Write-Note "restart requested: exe=$Executable delay=${DelayMs}ms"
Start-Sleep -Milliseconds ([Math]::Max(0, $DelayMs))

# Stop every DSH process, then wait for the name to disappear.
$running = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($running) {
    Write-Note ("stopping {0} process(es): {1}" -f $running.Count, (($running | ForEach-Object { $_.Id }) -join ','))
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
}

$left = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if ($left) {
    Write-Note ("abort: {0} process(es) still present after {1}s: {2}" -f $left.Count, $WaitSeconds, (($left | ForEach-Object { $_.Id }) -join ','))
    exit 1
}

# One more beat so the lock file handler can close.
Start-Sleep -Milliseconds 400

try {
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        Start-Process -FilePath $Executable
    } else {
        Start-Process -FilePath $Executable -WorkingDirectory $WorkingDirectory
    }
    Write-Note "relaunched"
} catch {
    Write-Note ("relaunch failed: " + $_.Exception.Message)
    exit 1
}