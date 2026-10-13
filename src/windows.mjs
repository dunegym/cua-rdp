import { spawn } from 'node:child_process';
import path from 'node:path';
import { ROOT } from './location.mjs';
import { powershellPath } from './util.mjs';

export function runPowerShellJson(relativeScript, args = [], { input, timeout = 30_000, spawnProcess = spawn } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(ROOT, relativeScript), ...args],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    let diagnostic = '';
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (error) reject(error); else resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(new Error(`${path.basename(relativeScript)} timed out; no automatic retry was attempted`));
    }, timeout);
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      output += chunk;
      if (output.length > 256 * 1024) { child.kill(); finish(new Error('Native diagnostic response exceeds its size limit')); }
    });
    child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-4000); });
    child.stdin.on('error', () => {});
    child.on('error', error => finish(new Error(`Cannot run ${path.basename(relativeScript)}: ${error.message}`)));
    child.on('close', code => {
      if (code !== 0) {
        // A failed PowerShell pipeline may echo stdin. Never include its diagnostic when stdin contained a token.
        finish(new Error(`${path.basename(relativeScript)} failed (${code})${input === undefined && diagnostic ? `: ${diagnostic.trim()}` : ''}`));
        return;
      }
      try { finish(null, JSON.parse(output.trim().replace(/^﻿/u, ''))); }
      catch { finish(new Error(`${path.basename(relativeScript)} returned invalid JSON`)); }
    });
    child.stdin.end(input === undefined ? undefined : `${JSON.stringify(input)}\n`);
  });
}

export const childSessionState = () => runPowerShellJson('native/Get-ChildSessionState.ps1');
