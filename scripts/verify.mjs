import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/location.mjs';
import { powershellPath } from '../src/util.mjs';

function run(label, executable, args) {
  process.stdout.write(`\n=== ${label} ===\n`);
  const result = spawnSync(executable, args, { cwd: ROOT, stdio: 'inherit', windowsHide: true, timeout: 120_000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${label} failed (${result.status ?? result.signal})`);
}

try {
  run('Build plugin bundles', process.execPath, ['scripts/build.mjs']);
  run('JavaScript syntax', process.execPath, ['scripts/check.mjs']);
  const tests = readdirSync(path.join(ROOT, 'test')).filter(file => file.endsWith('.test.mjs')).map(file => path.join(ROOT, 'test', file));
  run('Node regression tests', process.execPath, ['--test', ...tests]);
  if (process.platform !== 'win32') throw new Error('JavaScript checks passed, but full verification requires Windows for the PowerShell and ActiveX tests');
  for (const script of ['scripts/Test-PowerShell.ps1', 'scripts/Test-Transport.ps1', 'scripts/child/Test-ChildRuntime.ps1', 'native/Test-BootstrapKeyboard.ps1', 'native/Test-BootstrapInput.ps1', 'native/Test-Native.ps1']) {
    run(script, powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(ROOT, script)]);
  }
  const command = `$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; & claude plugin validate '${ROOT.replaceAll("'", "''")}' --strict; exit $LASTEXITCODE`;
  run('Claude Code plugin validation', powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64')]);
  process.stdout.write('\nAll local checks passed. No real VM/RDP connection was attempted; end-to-end acceptance is still required.\n');
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
