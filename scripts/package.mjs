import { runPowerShellJson } from '../src/windows.mjs';

if (process.platform !== 'win32') throw new Error('Packaging this Windows plugin requires PowerShell on Windows');
await import('./build.mjs');
const result = await runPowerShellJson('scripts/Package-Plugin.ps1', [], { timeout: 60_000 });
process.stdout.write(`Created ${result.archive} (${result.files} files)\n`);
