import { build } from 'esbuild';
import { ROOT } from '../src/location.mjs';
import path from 'node:path';
await build({
  entryPoints: [path.join(ROOT, 'guest', 'agent.mjs')], outfile: path.join(ROOT, 'dist', 'guest-agent.cjs'),
  bundle: true, platform: 'node', format: 'cjs', target: 'node22', sourcemap: false, logLevel: 'info',
});
// Marketplace installs need no npm install. Keep the entry one directory below
// the plugin root so location.mjs resolves native/, scripts/ and guest/ correctly.
await build({
  entryPoints: [path.join(ROOT, 'src', 'server.mjs')], outfile: path.join(ROOT, 'dist', 'desktop-server.mjs'),
  bundle: true, platform: 'node', format: 'esm', target: 'node22', sourcemap: false, logLevel: 'info',
  banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
});
