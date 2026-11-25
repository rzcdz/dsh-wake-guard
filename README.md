# Wake guard

A [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin bundle for
Windows laptops on Modern Standby: after the machine wakes from sleep, it keeps
the system awake for a grace period so a remote client has time to reconnect.

The bundle adds a sidebar entry with a switch, a status panel, **Sleep** and
**Restart** buttons, and three small PowerShell helpers. Nothing runs until you
turn the switch on.

## Sleep

The panel has a two-click **Sleep** button. It puts the machine into **Modern
Standby (S0ix)** — the state any key press wakes — and explicitly *not* S4
hibernation, which only the power button can leave.

It works by turning the display off (`SC_MONITORPOWER`): the power manager reads
that as loss of user presence and drops into S0ix a few seconds later.

`SetSuspendState` is deliberately avoided. This machine has no S1/S2/S3
(`powercfg /a`), so that call can resolve to S4. The Event Log tells the two
apart — event 506 with `Reason: SC_MONITORPOWER` is S0ix, while event 42 with
`Reason: Application API` is hibernation. Measured here: 506 on sleep, then 507
`Reason: Input Keyboard` on wake, and no event 42 at all.

The virtual sleep key (`VK_SLEEP`) is off by default for the same reason: on a
machine without S3 the power manager may resolve it to S4. `-IncludeSleepKey`
opts in, but confirm that key really enters S0ix on your hardware first.

## Restart

The panel has a two-click restart button: the first click arms it, the second
restarts. A restart **ends every running session**, so save first; the page
reloads itself once the Host answers again.

It prefers Electron's own `app.relaunch()` — the same path DSH's updater uses —
and falls back to a detached PowerShell helper that stops every DSH process,
waits until they are really gone, then starts the executable again. That wait
matters: Electron's single-instance lock makes a new process hand off to the
running one and exit, so starting too early would leave nothing running.

## The problem

Notebooks on Modern Standby (S0 low-power idle) go straight back to standby when
nothing happens after a wake. A remote session has only a few seconds to
reconnect before the network stack drops again.

The helper keeps the Host awake by sending `VK_F15` keystrokes in a loop — almost
no physical keyboard has that key, so it does not disturb any application while
Windows still sees an active user.

## Install

**From the DSH UI** — open **Plugins** → **Add plugin**, then enter:

```text
https://github.com/rzcdz/dsh-wake-guard
```

Accepted spec forms include `rzcdz/dsh-wake-guard`,
`github:rzcdz/dsh-wake-guard` and a full `https://github.com/...` URL.

**From an agent session** — ask DSH to run `plugin_manager` with
`action: install_bundle` and that URL as `target`.

**From a local clone** — point **Add plugin** at the clone's absolute path.

Installing does not start the helper; the sidebar switch does.

Requirements: Windows (`dsh.bundle.platforms` is `["win32"]`, so DSH refuses the
bundle on other Hosts) and PowerShell 5.1 or later.

## Usage

1. Click the icon at the bottom of the left sidebar to open the panel.
2. Turn the switch on.
3. The machine goes to sleep **once**, 10 seconds later.
4. Wake it (power button, or a smart plug cutting and restoring power).
   The helper holds the Host awake for about 10 minutes.
5. Turn the switch off to stop holding it; the normal sleep schedule resumes.

A green dot on the sidebar icon means the helper is running.

## Behaviour worth knowing

- **Sleep once after starting.** Starting the helper also requests one Modern
  Standby transition after `suspendDelaySec`, so you can flip the switch and walk
  away without closing the lid.
- **Modern Standby, not hibernation.** The helper calls the power API with
  `hibernate = false`. `rundll32 powrprof.dll,SetSuspendState 0,1,0` would take
  the S4 path when hibernation is enabled (write `hiberfil.sys`, cut power,
  firmware logo on the next press).
- **The screen lights up periodically** while the helper runs. That is the cost
  of staying awake; leave it on only as long as you need.
- **Stopping DSH stops the helper.** Unloading the bundle kills the child process
  and clears the pending timer.

## Configuration

`cordis.patch.yml` in the installed bundle:

```yaml
config:
  graceMinutes: 10      # minutes to hold the Host awake after each wake
  suspendDelaySec: 10   # delay before the single sleep request after starting
```

Disable and re-enable the plugin after changing them.

## Logs

`%LOCALAPPDATA%\dsh-wake-guard.log`; the panel shows the last 14 lines.

## Limits

- Windows only.
- The helper lives and dies with DSH.
- Periodic screen wake-ups cost battery; toggle it on demand.
- A few seconds pass between turning the switch off and the process exiting.
- Setting is per Host, not per Session.

## 中文说明

适用于 Modern Standby（S0 低电量待机）笔记本：从待机被唤醒后，如果没有活动，
系统会在几秒内重新进入待机，远程客户端来不及重连。本插件在侧边栏提供开关，
唤醒后持续模拟按键（`VK_F15`，几乎没有实体键盘有这个键），让 Windows 认为用户
在场，从而保持唤醒约 10 分钟。

安装：**插件** → **添加插件**，填入 `https://github.com/rzcdz/dsh-wake-guard`。
打开开关后机器会**先睡眠一次**（10 秒后），之后从睡眠唤醒才会保持可用。
仅 Windows 生效；屏幕会周期性亮起，建议按需开关。

## License

MIT
