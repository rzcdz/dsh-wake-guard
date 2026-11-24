window.__ModuleLoader__.load({
  id: '@rzcdz/dsh-wake-guard',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    const PANEL_ID = 'wake-guard';
    const API = '/dsh-wake-guard/api';

    async function call(path, method) {
      const res = await fetch(`${API}/${path}`, {
        method: method || 'GET',
        headers: { 'content-type': 'application/json' },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    }

    const CSS = `
      .wg-page {
        display: flex; flex-direction: column;
        width: 100%; height: 100%; min-height: 0;
        overflow: auto;
        box-sizing: border-box;
        padding: 22px 24px 28px;
        color: var(--dsw-alias-text-primary, #1f2328);
        font: 13px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
      }
      .wg-head { display: flex; align-items: center; gap: 10px; margin-bottom: 4px; }
      .wg-h1 { font-size: 17px; font-weight: 650; }
      .wg-sub {
        font-size: 12.5px; margin-bottom: 18px;
        color: var(--dsw-alias-text-secondary, #6b7280);
      }
      .wg-card {
        max-width: 620px;
        display: flex; align-items: center; gap: 14px;
        padding: 15px 16px; border-radius: 12px;
        background: var(--dsw-alias-bg-subtle, #f7f8fa);
        border: 1px solid var(--dsw-alias-border-default, #e6e9ee);
      }
      .wg-cardtext { flex: 1; min-width: 0; }
      .wg-label { font-weight: 600; font-size: 13.5px; }
      .wg-hint {
        font-size: 12.5px; margin-top: 3px;
        color: var(--dsw-alias-text-secondary, #6b7280);
      }
      .wg-dot {
        width: 9px; height: 9px; border-radius: 50%; flex: none;
        background: var(--dsw-alias-text-tertiary, #9aa1ab);
      }
      .wg-dot.on { background: #22c55e; }
      .wg-switch {
        position: relative; width: 44px; height: 25px; flex: none;
        border-radius: 999px; border: 0; cursor: pointer;
        background: var(--dsw-alias-border-strong, #c9ced6);
        transition: background .16s ease;
      }
      .wg-switch[aria-checked="true"] { background: #2f6fed; }
      .wg-switch::after {
        content: ""; position: absolute; top: 3px; left: 3px;
        width: 19px; height: 19px; border-radius: 50%;
        background: #fff; transition: transform .16s ease;
        box-shadow: 0 1px 3px rgba(0,0,0,.28);
      }
      .wg-switch[aria-checked="true"]::after { transform: translateX(19px); }
      .wg-switch:disabled { opacity: .55; cursor: progress; }
      .wg-meta {
        max-width: 620px; margin-top: 14px; font-size: 12.5px;
        color: var(--dsw-alias-text-secondary, #6b7280);
      }
      .wg-meta code, .wg-steps code {
        font-family: ui-monospace, Menlo, Consolas, monospace;
        background: var(--dsw-alias-bg-subtle, #eef0f4);
        padding: 1px 5px; border-radius: 4px;
      }
      .wg-steps {
        max-width: 620px; margin-top: 18px; padding: 14px 16px;
        border-radius: 12px;
        background: var(--dsw-alias-bg-subtle, #f7f8fa);
        border: 1px solid var(--dsw-alias-border-default, #e6e9ee);
        font-size: 12.5px;
        color: var(--dsw-alias-text-secondary, #55606e);
      }
      .wg-steps ol { margin: 8px 0 0; padding-left: 20px; }
      .wg-steps li { margin: 5px 0; }
      .wg-steps b { color: var(--dsw-alias-text-primary, #1f2328); }
      .wg-log {
        max-width: 620px; margin-top: 16px; padding: 11px 13px;
        border-radius: 10px; max-height: 200px; overflow: auto;
        background: var(--dsw-alias-bg-subtle, #f7f8fa);
        border: 1px solid var(--dsw-alias-border-default, #e6e9ee);
        font-family: ui-monospace, Menlo, Consolas, monospace;
        font-size: 11.5px; line-height: 1.65; white-space: pre-wrap;
        word-break: break-all;
        color: var(--dsw-alias-text-secondary, #55606e);
      }
      .wg-err { max-width: 620px; margin-top: 12px; font-size: 12.5px; color: #d84a3a; }
      .wg-restart {
        max-width: 620px; margin-top: 18px; padding: 14px 16px;
        border-radius: 12px; display: flex; align-items: center; gap: 14px;
        background: var(--dsw-alias-bg-subtle, #f7f8fa);
        border: 1px solid var(--dsw-alias-border-default, #e6e9ee);
      }
      .wg-restarttext { flex: 1; min-width: 0; }
      .wg-btn {
        padding: 7px 15px; border-radius: 8px; cursor: pointer; font: inherit;
        white-space: nowrap; border: 1px solid var(--dsw-alias-border-default, #dfe3e9);
        background: var(--dsw-alias-bg-base, #fff);
        color: var(--dsw-alias-text-primary, #1f2328);
      }
      .wg-btn:hover:not(:disabled) { background: var(--dsw-alias-bg-subtle, #f1f3f6); }
      .wg-btn:disabled { opacity: .55; cursor: progress; }
      .wg-btn.danger {
        background: #d84a3a; border-color: #d84a3a; color: #fff;
      }
      .wg-btn.danger:hover:not(:disabled) { filter: brightness(.94); }
    `;

    function Styles() {
      return h('style', null, CSS);
    }

    // Sun-ish mark reused by the sidebar row and the page header.
    function Mark({ size }) {
      const s = size || 16;
      return h('svg', {
        width: s, height: s, viewBox: '0 0 24 24',
        fill: 'none', stroke: 'currentColor', strokeWidth: 1.9,
        strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true, style: { display: 'block' },
      },
        h('circle', { cx: 12, cy: 12, r: 4 }),
        h('path', { d: 'M12 2v3M12 19v3M2 12h3M19 12h3' }),
        h('path', { d: 'M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9L17 7M7 17l-2.1 2.1' }),
      );
    }

    // Sidebar row icon. The sidebar supplies `size` and `active`.
    function SidebarIcon(props) {
      return h(Mark, { size: (props && props.size) || 16 });
    }

    function WakeGuardPage() {
      const [state, setState] = React.useState(null);
      const [busy, setBusy] = React.useState(false);
      const [error, setError] = React.useState('');

      const refresh = React.useCallback(async () => {
        try {
          const s = await call('state');
          setState(s);
          setError('');
        } catch (e) {
          setError(String((e && e.message) || e));
        }
      }, []);

      React.useEffect(() => {
        refresh();
        const timer = setInterval(refresh, 2000);
        return () => clearInterval(timer);
      }, [refresh]);

      const running = Boolean(state && state.running);

      const toggle = async () => {
        if (busy) return;
        setBusy(true);
        setError('');
        try {
          await call(running ? 'stop' : 'start', 'POST');
          await refresh();
        } catch (e) {
          setError(String((e && e.message) || e));
        } finally {
          setBusy(false);
        }
      };

      const delay = (state && state.suspendDelaySec) || 10;
      const grace = (state && state.graceMinutes) || 10;

      // Restart runs in two clicks: the first arms the button, the second
      // actually restarts, so a stray click cannot kill a running session.
      const [armed, setArmed] = React.useState(false);
      const [restarting, setRestarting] = React.useState(false);
      const [restartNote, setRestartNote] = React.useState('');
      const [capability, setCapability] = React.useState(null);

      React.useEffect(() => {
        let alive = true;
        call('restart')
          .then((value) => { if (alive) setCapability(value); })
          .catch(() => {});
        return () => { alive = false; };
      }, []);

      const doRestart = async () => {
        if (restarting) return;
        if (!armed) {
          setArmed(true);
          setRestartNote('再点一次确认重启。正在运行的会话会中断。');
          return;
        }
        setArmed(false);
        setRestarting(true);
        setRestartNote('正在重启，页面会在服务恢复后自动刷新。');
        try {
          await call('restart', 'POST');
        } catch (e) {
          setRestartNote(String((e && e.message) || e));
          setRestarting(false);
          return;
        }
        // The host is going away; wait for it to answer again.
        const deadline = Date.now() + 90000;
        const poll = async () => {
          if (Date.now() > deadline) {
            setRestartNote('没有等到 DSH 恢复，请手动重新打开。');
            setRestarting(false);
            return;
          }
          try {
            const probe = await fetch(`${API}/state`, { method: 'GET', cache: 'no-store' });
            if (probe.ok) {
              window.location.reload();
              return;
            }
          } catch {
            // Still down.
          }
          setTimeout(poll, 1500);
        };
        setTimeout(poll, 2500);
      };

      const restartHint = capability === null
        ? '检测中…'
        : capability.method === 'electron'
          ? '通过 Electron 重启当前应用。'
          : capability.method === 'helper'
            ? '通过独立助手进程结束并重新启动 DSH。'
            : '当前环境无法自动重启，请手动退出后重新打开。';

      return h('div', { className: 'wg-page' },
        h(Styles),
        h('div', { className: 'wg-head' },
          h(Mark, { size: 20 }),
          h('span', { className: 'wg-h1' }, '自动唤醒'),
        ),
        h('div', { className: 'wg-sub' },
          '保持电脑在唤醒后不重新进入待机，方便远程访问。',
        ),

        h('div', { className: 'wg-card' },
          h('span', { className: 'wg-dot' + (running ? ' on' : '') }),
          h('div', { className: 'wg-cardtext' },
            h('div', { className: 'wg-label' }, '运行'),
            h('div', { className: 'wg-hint' },
              running
                ? '保持中，屏幕会周期性亮起'
                : '已停止，系统恢复正常自动睡眠',
            ),
          ),
          h('button', {
            className: 'wg-switch',
            role: 'switch',
            'aria-checked': running ? 'true' : 'false',
            'aria-label': '运行开关',
            disabled: busy,
            onClick: toggle,
          }),
        ),

        h('div', { className: 'wg-meta' },
          '打开开关后 ',
          h('code', null, `${delay} 秒`),
          ' 会执行一次睡眠；每次唤醒后保持 ',
          h('code', null, `${grace} 分钟`),
          '。',
          state && state.pid
            ? h('span', null, ' 进程 ', h('code', null, String(state.pid)), '。')
            : null,
        ),

        h('div', { className: 'wg-steps' },
          h('b', null, '使用流程'),
          h('ol', null,
            h('li', null, '打开上面的开关，', h('code', null, `${delay} 秒`), ' 后电脑自动睡眠'),
            h('li', null, '用插座通电唤醒电脑'),
            h('li', null, `唤醒后自动保持 ${grace} 分钟，期间可远程访问`),
            h('li', null, '用完关闭开关，停止保持'),
          ),
        ),

        error ? h('div', { className: 'wg-err' }, error) : null,

        h('div', { className: 'wg-restart' },
          h('div', { className: 'wg-restarttext' },
            h('div', { className: 'wg-label' }, '重启'),
            h('div', { className: 'wg-hint' }, restartHint),
            restartNote !== ''
              ? h('div', { className: 'wg-hint', style: { color: '#d84a3a' } }, restartNote)
              : null,
          ),
          h('button', {
            className: armed ? 'wg-btn danger' : 'wg-btn',
            disabled: restarting || (capability !== null && capability.available !== true),
            onClick: doRestart,
            onBlur: () => setArmed(false),
          }, restarting ? '重启中…' : armed ? '确认' : '重启'),
        ),

        state && state.logTail
          ? h('div', { className: 'wg-log' }, state.logTail)
          : null,
      );
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        const t = (key) => (key === 'nav' ? '自动唤醒' : key);

        // The panel page, addressed by the same id the sidebar list uses.
        ctx.slots.inject('main', () =>
          ctx.slots.register({
            name: 'main',
            key: PANEL_ID,
          }, WakeGuardPage));

        // The sidebar row: icon plus the localized label.
        ctx.slots.inject('sidebar.panellist', () =>
          ctx.slots.register({
            name: 'sidebar.panellist',
            id: PANEL_ID,
            order: 20,
            label: () => t('nav'),
          }, SidebarIcon));
      },
    };
  },
});
