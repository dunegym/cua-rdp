import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/location.mjs';
for (const dir of ['src', 'guest', 'scripts', 'test']) {
  for (const file of readdirSync(path.join(ROOT, dir))) {
    if (file.endsWith('.mjs')) execFileSync(process.execPath, ['--check', path.join(ROOT, dir, file)], { stdio: 'inherit' });
  }
}

function* walk(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

// Windows PowerShell 5.1 (and the C# compiler behind Add-Type) decode BOM-less files
// with the system ANSI codepage, which differs per machine — non-ASCII literals would
// silently change meaning between a zh-CN developer box and an en-US CI runner.
// Keep .ps1/.cs sources pure ASCII and build Unicode test strings from code points.
for (const file of walk(ROOT)) {
  const relative = path.relative(ROOT, file).replaceAll('\\', '/');
  if (!/\.(ps1|cs)$/.test(file)) continue;
  if (/^(node_modules|dist|\.git)\//.test(relative)) continue;
  const bytes = readFileSync(file);
  const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  if (!hasBom && bytes.some(byte => byte > 0x7f)) {
    throw new Error(`${relative} has non-ASCII bytes without a UTF-8 BOM; Windows PowerShell 5.1 would decode it with the machine codepage. Build such strings from code points instead.`);
  }
}
process.stdout.write('JavaScript syntax checks passed; .ps1/.cs sources are ASCII-safe.\n');
