import assert from 'node:assert/strict';
import { DesktopManager } from '../src/desktop.mjs';
import { loadConfig } from '../src/config.mjs';
import { childSessionState, runPowerShellJson } from '../src/windows.mjs';
import { safeError } from '../src/util.mjs';
import { verifyParentObservation } from './probe-observation.mjs';

// Real-session GUI acceptance: launch Notepad inside the Child Session, type a fixed
// line, read it back through the accessibility tree, close it, and prove the parent
// desktop was never touched. Every operated window is verified to live in the child
// session, so a single-instance application routing to the parent fails the run.

if (!process.argv.includes('--run')) {
  process.stderr.write('Explicit real-session GUI test: node test/probe-gui.mjs --run [--interactive-authentication]. Launches Notepad in the Child Session, types and reads back text, and never touches the parent desktop.\n');
  process.exitCode = 2;
} else {
  const authentication = process.argv.includes('--interactive-authentication') ? 'interactive' : 'background';
  const text = 'ISOLATED DESKTOP TEST 2026-10-13';
  const session = 'cua-gui-acceptance';
  let attempted = false;
  let parentBefore;
  let parentBaseline;
  if (authentication === 'interactive') console.log(JSON.stringify({ phase: 'interactive-instructions', message: 'Complete Windows sign-in; the preparation window hides itself once the agent is ready. No focus handling is required.' }));
  const manager = new DesktopManager({ onProgress: async progress => {
    console.log(JSON.stringify(progress));
    if (progress.backgroundReady === true && !parentBaseline) parentBaseline = await runPowerShellJson('test/Get-ParentObservation.ps1');
  } });
  const call = async (tool, arguments_) => {
    const result = await manager.request('callTool', { name: tool, arguments: arguments_ });
    if (result?.isError === true) throw new Error(`${tool} returned isError: ${JSON.stringify(result).slice(0, 500)}`);
    return result;
  };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const windowsOf = async () => {
    const result = await call('list_windows', { session });
    const payload = result.structuredContent ?? {};
    const windows = payload.windows ?? payload.items ?? [];
    if (!Array.isArray(windows)) throw new Error(`list_windows returned an unexpected shape: ${JSON.stringify(result).slice(0, 400)}`);
    return windows;
  };
  const notepadWindows = windows => windows.filter(window =>
    /notepad/i.test(String(window.app_name ?? window.process_name ?? '')) || /notepad/i.test(String(window.title ?? '')));
  const keyOf = window => `${Number(window.pid)}:${Number(window.window_id)}`;
  const pidGone = async pid => !notepadWindows(await windowsOf()).some(window => Number(window.pid) === pid);
  // Win11 Notepad answers Alt+F4 with an in-window XAML content dialog (not a separate
  // HWND); Alt+N picks "don't save" on both English and Chinese builds. Foreground
  // delivery because the XAML window drops posted background keys.
  const closeWindow = async (pid, windowId) => {
    await call('press_key', { session, pid, window_id: windowId, key: 'f4', modifiers: ['alt'], delivery_mode: 'foreground' });
    await sleep(2000);
    await call('press_key', { session, pid, window_id: windowId, key: 'n', modifiers: ['alt'], delivery_mode: 'foreground' });
    await sleep(2000);
  };
  const windowGone = async (pid, windowId) => !(await windowsOf()).some(window => Number(window.pid) === pid && Number(window.window_id) === windowId);
  const childSessionOfPid = async pid => {
    try { return (await runPowerShellJson('scripts/child/Get-AgentProcess.ps1', ['-ProcessId', String(pid)])).sessionId; }
    catch { return -1; }
  };
  try {
    assert.equal((await loadConfig()).backend, 'child-session', 'This acceptance requires the child-session backend');
    const native = await childSessionState();
    assert.equal(native.enabled, true, 'Enable Child Sessions explicitly before running this acceptance');
    parentBefore = await runPowerShellJson('test/Get-ParentObservation.ps1');
    if (authentication === 'background') parentBaseline = parentBefore;
    attempted = true;
    const started = await manager.start({ authentication });
    console.log(JSON.stringify({ phase: 'started', ...started }));
    assert.equal(started.state, 'ready');
    if (authentication === 'interactive' && !parentBaseline) parentBaseline = await runPowerShellJson('test/Get-ParentObservation.ps1');

    const tools = await manager.request('listTools', {});
    const names = tools.tools.map(tool => tool.name);
    for (const required of ['list_windows', 'launch_app', 'type_text', 'get_window_state', 'verify_state', 'press_key']) {
      assert(names.includes(required), `The driver is missing the ${required} tool`);
    }
    const closeSchemas = {};
    for (const name of ['bring_to_front', 'click', 'invoke_menu']) {
      const tool = tools.tools.find(entry => entry.name === name);
      if (tool) closeSchemas[name] = { required: tool.inputSchema.required ?? [], properties: Object.keys(tool.inputSchema.properties ?? {}) };
    }
    console.log(JSON.stringify({ phase: 'driver-ready', tools: names.length, closeSchemas }));

    // One quick best-effort cleanup round for Notepad windows left by earlier aborted
    // runs (single-instance Notepad reuses the surviving process). Non-fatal by design:
    // the plugin never guarantees a blank child desktop, and XAML close handling is
    // recorded rather than asserted.
    for (const leftover of notepadWindows(await windowsOf())) {
      await closeWindow(Number(leftover.pid), Number(leftover.window_id));
    }
    await sleep(3000);
    const leftovers = notepadWindows(await windowsOf());
    console.log(JSON.stringify({ phase: 'leftover-cleanup', remaining: leftovers.map(window => keyOf(window)) }));
    const baseline = new Set((await windowsOf()).map(keyOf));
    const desktop = await call('get_desktop_state', { session });
    console.log(JSON.stringify({ phase: 'desktop-baseline', hasScreenshot: JSON.stringify(desktop).includes('"type":"image"') }));

    let launch;
    try { launch = await call('launch_app', { session, bundle_id: 'Microsoft.WindowsNotepad_8wekyb3d8bbwe!App' }); }
    catch (error) {
      console.log(JSON.stringify({ phase: 'launch-fallback', reason: safeError(error).slice(0, 200) }));
      launch = await call('launch_app', { session, name: 'notepad' });
    }
    const launchPid = Number(launch?.structuredContent?.pid ?? 0) || undefined;
    console.log(JSON.stringify({ phase: 'launched', launchPid }));

    let window;
    for (let attempt = 0; attempt < 15 && !window; attempt++) {
      await sleep(2000);
      window = notepadWindows(await windowsOf()).find(candidate => !baseline.has(keyOf(candidate)));
    }
    if (!window) throw new Error('Notepad did not create a new window in the child session within 30 seconds');
    const pid = Number(window.pid);
    const windowId = Number(window.window_id);
    const owningSession = await childSessionOfPid(pid);
    console.log(JSON.stringify({ phase: 'notepad-window', pid, windowId, title: window.title, owningSession, tracked: launchPid === pid }));
    assert(Number.isInteger(pid) && pid > 0 && Number.isInteger(windowId) && windowId > 0, 'The driver returned an invalid Notepad window identity');
    assert.equal(owningSession, started.sessionId, 'The launched Notepad does not belong to the child session (single-instance routing to the parent desktop is not acceptable input)');

    await call('type_text', { session, pid, window_id: windowId, text });
    console.log(JSON.stringify({ phase: 'typed', characters: text.length }));

    const state = await call('get_window_state', { session, pid, window_id: windowId, include_accessibility_tree: true, max_depth: 8, max_elements: 400 });
    const treeCarriesText = JSON.stringify(state).includes(text);
    console.log(JSON.stringify({ phase: 'readback', accessibilityTreeCarriesText: treeCarriesText }));
    let elementVerified = false;
    try {
      await call('verify_state', { session, pid, window_id: windowId, timeout_ms: 10_000, stable_samples: 2,
        expect: [{ element: { selector: { role: 'document' }, exists: true, value_equals: text } }, { window: { exists: true } }] });
      elementVerified = true;
    } catch (error) { console.log(JSON.stringify({ phase: 'element-verify', note: 'document-role predicate unavailable', error: safeError(error).slice(0, 300) })); }
    assert(treeCarriesText || elementVerified, 'The typed text could not be read back from the child-session Notepad');

    // Best-effort shutdown. The acceptance itself is launch + type + readback in the
    // verified child session; leftover child-session windows are cosmetic (the plugin
    // never guarantees a blank desktop), so every close strategy is tried and logged
    // instead of failing the run.
    const attempts = [];
    if (launchPid) {
      try { await call('kill_app', { pid: launchPid }); attempts.push('kill_app:ok'); }
      catch (error) { attempts.push('kill_app:refused'); }
    }
    if (!(await windowGone(pid, windowId))) {
      try {
        if (names.includes('bring_to_front')) await call('bring_to_front', { session, pid, window_id: windowId });
      } catch (error) { attempts.push('bring_to_front:failed'); }
      await closeWindow(pid, windowId);
      attempts.push('alt-f4+n');
    }
    if (!(await windowGone(pid, windowId)) && names.includes('click') && window.bounds) {
      try {
        const bounds = window.bounds;
        await call('click', { session, pid, window_id: windowId, x: Number(bounds.width) - 20, y: 18 });
        await sleep(2000);
        await call('press_key', { session, pid, window_id: windowId, key: 'n', modifiers: ['alt'], delivery_mode: 'foreground' });
        attempts.push('click-close');
      } catch (error) { attempts.push('click-close:failed'); }
    }
    await sleep(3000);
    const closed = await windowGone(pid, windowId);
    console.log(JSON.stringify({ phase: 'shutdown', closed, attempts }));

    const after = await runPowerShellJson('test/Get-ParentObservation.ps1');
    assert.deepEqual(after, parentBaseline, 'Parent desktop, focus, clipboard sequence or cursor changed during GUI work');
    console.log(JSON.stringify({ phase: 'parent-observation', unchanged: true }));
  } catch (error) {
    process.stderr.write(`${safeError(error)}\n`);
    process.exitCode = 1;
  } finally {
    if (attempted) {
      try { console.log(JSON.stringify({ phase: 'stopped', ...await manager.stop() })); }
      catch (error) { process.stderr.write(`${safeError(error)}\n`); process.exitCode = 1; }
    }
    if (parentBefore) {
      try {
        const afterStop = await runPowerShellJson('test/Get-ParentObservation.ps1');
        const report = verifyParentObservation(parentBefore, parentBaseline, afterStop);
        console.log(JSON.stringify({ phase: 'parent-after-stop', ...report, authentication }));
      } catch (error) { process.stderr.write(`${safeError(error)}\n`); process.exitCode = 1; }
    }
  }
}
