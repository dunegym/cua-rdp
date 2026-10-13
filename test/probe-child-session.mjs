import assert from 'node:assert/strict';
import { DesktopManager } from '../src/desktop.mjs';
import { loadConfig } from '../src/config.mjs';
import { childSessionState, runPowerShellJson } from '../src/windows.mjs';
import { safeError } from '../src/util.mjs';
import { verifyParentObservation } from './probe-observation.mjs';

if (!process.argv.includes('--run')) {
  process.stderr.write('Explicit real-session test: node test/probe-child-session.mjs --run. Creates a Child Session and leaves it disconnected, not logged off. Never enables Windows features.\n');
  process.exitCode = 2;
} else {
  let attempted = false;
  let parentBefore;
  let parentBaseline;
  const authentication = process.argv.includes('--interactive-authentication') ? 'interactive' : 'background';
  if (authentication === 'interactive') console.log(JSON.stringify({ phase: 'interactive-instructions', message: 'Complete Windows sign-in, then keep the RDP preparation window focused until it hides. If waiting-input-focus is shown, click its title bar, not the remote desktop. No host focus is set automatically.' }));
  const manager = new DesktopManager({ onProgress: async progress => {
    console.log(JSON.stringify(progress));
    if (progress.backgroundReady === true && !parentBaseline) parentBaseline = await runPowerShellJson('test/Get-ParentObservation.ps1');
  } });
  try {
    assert.equal((await loadConfig()).backend, 'child-session', 'This probe requires the child-session backend');
    const native = await childSessionState();
    assert.equal(native.enabled, true, 'Enable Child Sessions explicitly before running this probe');
    if (native.childSessionId !== null) {
      console.log(JSON.stringify({ phase: 'resuming', childSessionId: native.childSessionId, childState: native.childState }));
    }
    parentBefore = await runPowerShellJson('test/Get-ParentObservation.ps1');
    if (authentication === 'background') parentBaseline = parentBefore;
    attempted = true;
    const started = await manager.start({ authentication });
    console.log(JSON.stringify({ phase: 'started', ...started }));
    assert.equal(started.state, 'ready');
    assert.notEqual(started.sessionId, parentBefore.sessionId);
    if (authentication === 'interactive') {
      if (!parentBaseline) parentBaseline = await runPowerShellJson('test/Get-ParentObservation.ps1');
      console.log(JSON.stringify({ phase: 'authentication', mode: 'interactive', visibleLogonExplicitlyAllowed: true, sameConnection: true }));
    }
    const tools = await manager.request('listTools');
    const names = ['get_desktop_state', 'list_windows', 'get_screen_size', 'get_window_state', 'launch_app', 'type_text', 'press_key', 'verify_state', 'kill_app'];
    console.log(JSON.stringify({ phase: 'driver-tools', tools: tools.tools.filter(tool => names.includes(tool.name)), nextCursor: tools.nextCursor }));
    try {
      const resource = await manager.request('readResource', { uri: 'skill://cua-driver/SKILL.md' });
      assert(resource.contents.some(content => typeof content.text === 'string' && content.text.length > 0), 'Driver skill was empty');
      console.log(JSON.stringify({ phase: 'driver-skill', read: true }));
    } catch (error) { console.log(JSON.stringify({ phase: 'driver-skill', error: safeError(error) })); }
    const screenTool = tools.tools.find(tool => tool.name === 'get_screen_size');
    if (screenTool && (screenTool.inputSchema.required ?? []).every(name => name === 'session')) {
      const args = screenTool.inputSchema.properties?.session ? { session: 'cua-rdp-acceptance' } : {};
      const screen = await manager.request('callTool', { name: screenTool.name, arguments: args });
      assert.notEqual(screen.isError, true, 'Driver could not read the child screen');
      console.log(JSON.stringify({ phase: 'child-screen', result: screen }));
    } else throw new Error('The probe cannot call the discovered get_screen_size schema safely');
    const after = await runPowerShellJson('test/Get-ParentObservation.ps1');
    assert.deepEqual(after, parentBaseline, 'Parent desktop, focus, clipboard sequence or cursor changed during background work');
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
