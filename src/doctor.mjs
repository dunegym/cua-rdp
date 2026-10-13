import { access } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { ROOT } from './location.mjs';
import { configPath, dataRoot, readJson, powershellPath, safeError } from './util.mjs';
import { loadConfig } from './config.mjs';
import { childSessionState } from './windows.mjs';
import { connectionPlan } from './child-session.mjs';

const exec = promisify(execFile);

export async function doctor() {
  const checks = [
    { name: 'Node.js >=22', ok: Number(process.versions.node.split('.')[0]) >= 22, detail: process.version },
    { name: 'Windows host', ok: process.platform === 'win32', detail: process.platform },
  ];
  let config;
  try {
    config = await loadConfig();
    let saved = true;
    try { await access(configPath()); } catch (error) { if (error.code === 'ENOENT') saved = false; else throw error; }
    checks.push({ name: 'Configuration', ok: true, detail: { backend: config.backend, source: saved ? configPath() : 'automatic Child Session defaults' } });
  } catch (error) { checks.push({ name: 'Configuration', ok: false, detail: safeError(error) }); }
  try {
    await access(path.join(ROOT, 'dist', 'guest-agent.cjs'));
    checks.push({ name: 'Built desktop agent', ok: true });
  } catch { checks.push({ name: 'Built desktop agent', ok: false, detail: 'The bundled agent is missing; reinstall the plugin (marketplace copies ship dist/guest-agent.cjs), or run npm ci && npm run build in a source checkout.' }); }
  if (process.platform === 'win32' && config?.backend === 'child-session') {
    try {
      await access(config.driverPath);
      checks.push({ name: 'Local cua-driver executable', ok: true, detail: config.driverPath });
    } catch { checks.push({ name: 'Local cua-driver executable', ok: false, detail: 'Install cua-driver or set CUA_RDP_DRIVER to its absolute .exe path.' }); }
    try {
      const state = await childSessionState();
      let owner;
      try { owner = await readJson(path.join(dataRoot(), 'child-session.owner.json')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      checks.push({ name: 'Native Child Session state', ok: true, detail: state });
      try {
        const plan = connectionPlan(state, owner);
        checks.push({ name: 'Child Session available', ok: true, detail: plan.expectedChildSessionId === null ? 'Ready to create; no connection attempted' : 'Exact owned disconnected child may be resumed; no connection attempted' });
      } catch (error) { checks.push({ name: 'Child Session available', ok: false, detail: safeError(error) }); }
    } catch (error) { checks.push({ name: 'Native Child Session state', ok: false, detail: safeError(error) }); }
  } else if (process.platform === 'win32' && config?.backend === 'hyperv') {
    try {
      const { stdout } = await exec(powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
        "$ErrorActionPreference='Stop'; Get-Command Get-VM -ErrorAction Stop | Out-Null; @(Get-VM -ErrorAction Stop).Count"], { windowsHide: true, timeout: 15_000 });
      checks.push({ name: 'Hyper-V management access', ok: true, detail: `${stdout.trim()} existing VM(s); no changes made` });
    } catch { checks.push({ name: 'Hyper-V management access', ok: false, detail: 'Hyper-V module or management permission unavailable. No elevation was attempted.' }); }
  }
  return {
    ok: checks.every(check => check.ok), backend: config?.backend, checks, systemChanges: false, connectionAttempted: false,
    prerequisites: config?.backend === 'hyperv' ? [
      'Dedicated licensed Windows VM with working RDP/NLA and a trusted name-matching RDP certificate',
      'Guest Node.js >=22, cua-driver >=0.34.0 and Explorer',
      'Saved guest credentials belong to the same host Windows user who runs Claude Code',
    ] : [
      'Supported Windows with native Child Sessions explicitly enabled and an active local console parent',
      'Local cua-driver >=0.34.0 and a PowerShell policy that runs local scripts (default RemoteSigned)',
      'A safe ASCII runtimeRoot; the Task Scheduler service must be available for the one-shot agent launch',
      'Child Session shares the same user and filesystem; it is not a security sandbox',
    ],
  };
}
