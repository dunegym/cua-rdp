import { build } from 'esbuild';
import { ROOT } from '../src/location.mjs';
import path from 'node:path';
await build({
  entryPoints: [path.join(ROOT, 'guest', 'agent.mjs')], outfile: path.join(ROOT, 'dist', 'guest-agent.cjs'),
  bundle: true, platform: 'node', format: 'cjs', target: 'node22', sourcemap: false, logLevel: 'info',
});
