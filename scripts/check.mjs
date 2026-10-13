import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/location.mjs';
for (const dir of ['src', 'guest', 'scripts', 'test']) {
  for (const file of readdirSync(path.join(ROOT, dir))) {
    if (file.endsWith('.mjs')) execFileSync(process.execPath, ['--check', path.join(ROOT, dir, file)], { stdio: 'inherit' });
  }
}
process.stdout.write('JavaScript syntax checks passed.\n');
