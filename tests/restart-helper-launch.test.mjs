/**
 * Verify the WMI-based helper launch end to end.
 *
 * Only this path is tested: it is the one that has to work from inside the
 * plugin. Process name is fake, so nothing is killed; the helper's own log is
 * the evidence, and the launcher exits immediately afterwards to prove the
 * helper outlives it.
 */
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const base = process.env.LOCALAPPDATA ?? os.tmpdir()
const log = path.join(base, 'dsh-wake-guard-restart.log')
if (fs.existsSync(log)) fs.rmSync(log)

const script = 'D:\\dshfree\\dsh-wake-guard\\scripts\\Restart-DSH.ps1'
const q = (v) => `"${v}"`
const commandLine = [
  'powershell.exe',
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-WindowStyle', 'Hidden',
  '-File', q(script),
  '-ProcessName', 'NoSuchProcessXyz',
  '-Executable', q('D:\\DSHNEXT\\DSH NEXT\\DSH NEXT.exe'),
  '-WorkingDirectory', q('D:\\DSHNEXT\\DSH NEXT'),
  '-DelayMs', '1200',
].join(' ')

const trampoline = [
  '$ErrorActionPreference = "Stop"',
  `$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = @'`,
  commandLine,
  `'@ }`,
  'if ($r.ReturnValue -ne 0) { Write-Error "failed: $($r.ReturnValue)"; exit 1 }',
  'Write-Output $r.ProcessId',
].join('\n')

const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', trampoline], {
  encoding: 'utf8',
  windowsHide: true,
  timeout: 20000,
})
console.log('trampoline status:', result.status)
console.log('trampoline stdout:', (result.stdout ?? '').trim())
if (result.stderr?.trim()) console.log('trampoline stderr:', result.stderr.trim())

// The launcher has now exited. If the helper survived, the log will appear.
await new Promise(r => setTimeout(r, 7000))
const ran = fs.existsSync(log)
console.log('\nhelper ran after launcher exited:', ran)
if (ran) for (const line of fs.readFileSync(log, 'utf8').trim().split(/\r?\n/)) console.log('   ' + line)
if (ran) fs.rmSync(log)
process.exit(ran ? 0 : 1)