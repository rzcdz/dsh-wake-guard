import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import path from 'node:path'
import os from 'node:os'
import fs from 'node:fs'

export const name = 'wake-guard'

// webServer backs the panel's routes; without this declaration the context
// refuses property access at activation.
export const inject = ['webServer']

/**
 * Host side of the wake guard.
 *
 * Loading this plugin starts nothing. Activation only registers the routes that
 * back the panel; the helper process starts when the user flips the switch, and
 * stops when they turn it off again.
 *
 * Routes:
 *   GET  /dsh-wake-guard/api/state  -> { running, pid, startedAt, logTail }
 *   POST /dsh-wake-guard/api/start  -> spawn helper, then suspend once after
 *                                      suspendDelaySec
 *   POST /dsh-wake-guard/api/stop   -> kill helper
 *
 * The single suspend after start is intentional: the helper exists to keep the
 * machine awake, so turning it on should also put the machine to sleep once,
 * letting the user walk away without touching the lid.
 */
export function apply(ctx, config = {}) {
  const graceMinutes = Number(config.graceMinutes ?? 10)
  const suspendDelaySec = Number(config.suspendDelaySec ?? 10)
  const packageDir = path.dirname(fileURLToPath(import.meta.url))
  const script = path.join(packageDir, 'scripts', 'WakeGuard.ps1')
  const logFile = path.join(
    process.env.LOCALAPPDATA || os.tmpdir(),
    'dsh-wake-guard.log',
  )

  const isWin = process.platform === 'win32'

  let child = null
  let startedAt = null
  let suspendTimer = null
  let suspendState = 'idle' // idle | scheduled | done | skipped

  const log = (message) => ctx.logger?.info?.(`wake-guard: ${message}`)
  const warn = (message) => ctx.logger?.warn?.(`wake-guard: ${message}`)

  const snapshot = () => ({
    running: Boolean(child),
    pid: child?.pid ?? null,
    startedAt: startedAt ? startedAt.toISOString() : null,
    graceMinutes,
    suspendDelaySec,
    suspendState,
    platform: process.platform,
  })

  const readLogTail = () => {
    try {
      if (!fs.existsSync(logFile)) return ''
      const lines = fs.readFileSync(logFile, 'utf8').split(/\r?\n/).filter(Boolean)
      return lines.slice(-14).join('\n')
    } catch {
      return ''
    }
  }

  // Put the machine into Modern Standby (S0ix), not hibernation.
  //
  // rundll32 powrprof.dll,SetSuspendState 0,1,0 looks like "sleep", but with
  // hibernation enabled the power manager takes the S4 path: it writes the
  // session to hiberfil.sys, cuts power, and the next power button press shows
  // the firmware logo before restoring. The helper script calls the API with
  // hibernate=$false, which asks for the low-power idle path instead.
  const suspendScript = path.join(packageDir, 'scripts', 'Suspend-Standby.ps1')

  const suspendOnce = () => {
    if (!fs.existsSync(suspendScript)) {
      warn(`suspend script missing: ${suspendScript}`)
      return
    }
    try {
      const ps = spawn(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          suspendScript,
        ],
        { stdio: 'ignore', windowsHide: true },
      )
      ps.on('error', (err) => warn(`suspend helper failed: ${err.message}`))
      log('suspend requested (Modern Standby path)')
    } catch (err) {
      warn(`suspend threw: ${err?.message ?? err}`)
    }
  }

  const clearSuspend = () => {
    if (suspendTimer) {
      clearTimeout(suspendTimer)
      suspendTimer = null
    }
  }

  const start = () => {
    if (!isWin) return { ok: false, error: '仅支持 Windows' }
    if (child) return { ok: true, already: true, ...snapshot() }

    child = spawn(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script,
        '-GraceMinutes',
        String(graceMinutes),
        '-LogFile',
        logFile,
      ],
      { stdio: 'ignore', windowsHide: true },
    )

    startedAt = new Date()
    log(`helper started pid=${child.pid}`)

    child.on('exit', (code) => {
      log(`helper exited code=${code}`)
      child = null
      startedAt = null
    })
    child.on('error', (err) => {
      warn(`helper spawn error: ${err.message}`)
      child = null
      startedAt = null
    })

    // Schedule the one-time suspend.
    clearSuspend()
    suspendState = 'scheduled'
    suspendTimer = setTimeout(() => {
      suspendTimer = null
      if (!child) {
        suspendState = 'skipped'
        return
      }
      suspendState = 'done'
      suspendOnce()
    }, Math.max(1, suspendDelaySec) * 1000)

    return { ok: true, ...snapshot() }
  }

  const stop = () => {
    clearSuspend()
    if (child) {
      try {
        child.kill()
      } catch {
        // already gone
      }
      log('helper stopped')
      child = null
      startedAt = null
    }
    suspendState = 'idle'
    return { ok: true, ...snapshot() }
  }

  // ---------------------------------------------------------------------
  // Restarting DSH
  //
  // The Host runs inside the Electron main process, so the app can relaunch
  // itself the way DSH's own updater does. A Host that cannot reach Electron
  // falls back to a detached PowerShell helper, which must outlive the process
  // it replaces — hence `detached` plus `unref`.
  // ---------------------------------------------------------------------

  /** How long the HTTP reply is given to flush before the process goes away. */
  const RESTART_FLUSH_MS = 600

  const restartScript = path.join(packageDir, 'scripts', 'Restart-DSH.ps1')

  /**
   * The Electron app object, when this Host is the Electron main process.
   * @returns the app, or null when this Host is a plain Node process.
   */
  const electronApp = () => {
    if (process.versions.electron === undefined) return null
    try {
      const require = createRequire(import.meta.url)
      const electron = require('electron')
      const app = electron?.app
      if (app === undefined || app === null) return null
      if (typeof app.relaunch !== 'function' || typeof app.exit !== 'function') return null
      return app
    } catch {
      return null
    }
  }

  const restartCapability = () => {
    const app = electronApp()
    return {
      available: app !== null || (isWin && fs.existsSync(restartScript)),
      method: app !== null ? 'electron' : (fs.existsSync(restartScript) ? 'helper' : 'unavailable'),
      platform: process.platform,
      executable: process.execPath,
      helper: fs.existsSync(restartScript),
    }
  }

  /**
   * Launch the restart helper outside this process tree.
   *
   * Measured on Windows, in the order they were tried:
   *
   * 1. `spawn(powershell, ..., { detached: true })` — the child is created,
   *    reports exit 0, and never runs the script. 0 of 20 probes wrote their
   *    marker. A restart built on it reports success and changes nothing.
   * 2. `spawn(cmd.exe, ['/c','start','/b','','powershell.exe', ...args])` — it
   *    runs while the launcher is alive, but dies with it: the child is still a
   *    descendant, and a console-hosted grandchild stalls when the console goes
   *    away. The restart helper must outlive the DSH process, so this is out.
   * 3. WMI's `Win32_Process.Create` — the new process is created by the WMI
   *    service, so it is not our child, survives our exit, and gets no console
   *    to stall on. This is the only form that has actually restarted DSH.
   *
   * The script path and executable can contain spaces and are passed as a
   * single quoted string, which is what PowerShell's own parser expects here.
   * @returns the new process id.
   */
  const spawnRestartHelper = () => {
    const quoteless = (value) => `"${value}"`
    const commandLine = [
      'powershell.exe',
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-WindowStyle', 'Hidden',
      '-File', quoteless(restartScript),
      '-Executable', quoteless(process.execPath),
      '-WorkingDirectory', quoteless(path.dirname(process.execPath)),
      '-DelayMs', String(RESTART_FLUSH_MS),
    ].join(' ')
    const script = [
      '$ErrorActionPreference = "Stop"',
      `$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = @'`,
      commandLine,
      `'@ }`,
      'if ($r.ReturnValue -ne 0) { Write-Error "Win32_Process.Create failed: $($r.ReturnValue)"; exit 1 }',
      'Write-Output $r.ProcessId',
    ].join('\n')
    // Run the trampoline synchronously: it only creates the helper, so it
    // finishes in well under a second and cannot keep us alive.
    const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 20_000,
    })
    if (result.error) throw result.error
    const pid = (result.stdout ?? '').trim()
    if (result.status !== 0) {
      throw new Error(result.stderr?.trim() || `helper launch failed (status ${result.status})`)
    }
    return pid === '' ? null : Number(pid)
  }

  /**
   * Restart DSH.
   *
   * The reply has to reach the browser before the process dies, so the actual
   * relaunch is deferred by one flush window.
   * @returns what was scheduled.
   */
  const restart = () => {
    const app = electronApp()
    if (app !== null) {
      setTimeout(() => {
        try {
          app.relaunch()
          app.exit(0)
        } catch (error) {
          warn(`relaunch failed, falling back to the helper: ${error?.message ?? error}`)
          try {
            spawnRestartHelper()
          } catch (helperError) {
            warn(`restart helper unavailable: ${String(helperError)}`)
          }
        }
      }, RESTART_FLUSH_MS)
      log('restart scheduled through Electron')
      return { ok: true, method: 'electron' }
    }
    // Fail loudly when the helper cannot be started: a restart that quietly
    // does nothing is worse than an error the panel can show.
    const pid = spawnRestartHelper()
    log(`restart helper started, pid=${pid ?? 'unknown'}`)
    return { ok: true, method: 'helper', helperPid: pid }
  }

  // Plugin unload must not leave a helper or a pending timer behind.
  ctx.effect(() => () => stop())

  const sendJson = (res, code, body) => {
    try {
      res.writeHead(code, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      })
      res.end(JSON.stringify(body))
    } catch {
      // response already closed
    }
  }

  ctx.effect(() => {
    const disposers = []

    disposers.push(
      ctx.webServer.register({
        kind: 'exact',
        path: '/dsh-wake-guard/api/state',
        handler: (req, res) => {
          if (req.method !== 'GET' && req.method !== 'HEAD') {
            sendJson(res, 405, { ok: false, error: 'use GET' })
            return
          }
          sendJson(res, 200, { ok: true, ...snapshot(), logTail: readLogTail() })
        },
      }),
    )

    disposers.push(
      ctx.webServer.register({
        kind: 'exact',
        path: '/dsh-wake-guard/api/start',
        handler: (req, res) => {
          if (req.method !== 'POST') {
            sendJson(res, 405, { ok: false, error: 'use POST' })
            return
          }
          sendJson(res, 200, start())
        },
      }),
    )

    disposers.push(
      ctx.webServer.register({
        kind: 'exact',
        path: '/dsh-wake-guard/api/stop',
        handler: (req, res) => {
          if (req.method !== 'POST') {
            sendJson(res, 405, { ok: false, error: 'use POST' })
            return
          }
          sendJson(res, 200, stop())
        },
      }),
    )

    disposers.push(
      ctx.webServer.register({
        kind: 'exact',
        path: '/dsh-wake-guard/api/restart',
        handler: (req, res) => {
          if (req.method === 'GET' || req.method === 'HEAD') {
            sendJson(res, 200, { ok: true, ...restartCapability() })
            return
          }
          if (req.method !== 'POST') {
            sendJson(res, 405, { ok: false, error: 'use GET or POST' })
            return
          }
          const capability = restartCapability()
          if (!capability.available) {
            sendJson(res, 501, { ok: false, error: '当前环境无法重启 DSH', ...capability })
            return
          }
          try {
            sendJson(res, 200, { ok: true, ...restart() })
          } catch (error) {
            sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
          }
        },
      }),
    )

    return () => {
      for (const dispose of disposers) {
        try {
          dispose()
        } catch {
          // already disposed
        }
      }
    }
  })
}
