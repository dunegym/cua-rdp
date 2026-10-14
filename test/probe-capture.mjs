import assert from 'node:assert/strict';
import { DesktopManager } from '../src/desktop.mjs';
import { loadConfig } from '../src/config.mjs';
import { childSessionState, runPowerShellJson } from '../src/windows.mjs';
import { safeError } from '../src/util.mjs';

// Capture diagnostic: which watch-window states keep the child session's RDP graphics
// pipeline alive? GDI BitBlt inside the child session fails with an invalid handle
// (0x80070006) when the client control stops presenting (minimized or hidden window).
// This probe walks the window states and records screenshot success for each.

if (!process.argv.includes('--run')) {
  process.stderr.write('Explicit real-session test: node test/probe-capture.mjs --run --interactive-authentication.\n');
  process.exitCode = 2;
} else {
  const session = 'cua-capture-probe';
  let attempted = false;
  const manager = new DesktopManager({ onProgress: async progress => { console.log(JSON.stringify(progress)); } });
  const windowState = action => runPowerShellJson('test/Window-State.ps1', ['-Action', action]);
  const capture = async label => {
    try {
      const result = await manager.request('callTool', { name: 'get_desktop_state', arguments: { session } });
      const failed = result?.isError === true || JSON.stringify(result).includes('BitBlt failed');
      console.log(JSON.stringify({ state: label, capture: failed ? 'FAILED' : 'ok' }));
      return !failed;
    } catch (error) {
      console.log(JSON.stringify({ state: label, capture: 'FAILED', error: safeError(error).slice(0, 200) }));
      return false;
    }
  };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  try {
    assert.equal((await loadConfig()).backend, 'child-session', 'This probe requires the child-session backend');
    assert.equal((await childSessionState()).enabled, true, 'Enable Child Sessions first');
    attempted = true;
    const started = await manager.start({ authentication: 'interactive' });
    assert.equal(started.state, 'ready');
    await sleep(2000);
    const steps = [
      ['visible-on-screen', 'state'],
      ['minimized-taskbar', 'minimize'],
      ['hidden-tray', 'hide'],
      ['visible-off-screen', 'offscreen'],
      ['restored-on-screen', 'restore'],
    ];
    for (const [label, action] of steps) {
      if (action !== 'state') {
        const after = await windowState(action);
        console.log(JSON.stringify({ state: label, window: after }));
        await sleep(2500);
      }
      await capture(label);
    }
  } catch (error) {
    process.stderr.write(`${safeError(error)}\n`);
    process.exitCode = 1;
  } finally {
    if (attempted) {
      try { await windowState('restore').catch(() => {}); } catch { }
      try { console.log(JSON.stringify({ phase: 'stopped', ...await manager.stop() })); }
      catch (error) { process.stderr.write(`${safeError(error)}\n`); process.exitCode = 1; }
    }
  }
}
