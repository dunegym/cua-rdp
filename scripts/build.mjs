import { build } from 'esbuild';
import { mkdir, writeFile } from 'node:fs/promises';
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
// The ZCode panel is served by the plugin's own MCP server from ui/panel.html. The page must
// stay self-contained (the host loads it from the resource text, with no network access), so
// the bundle is inlined into a single HTML document like the other committed bundles.
const panel = await build({
  entryPoints: [path.join(ROOT, 'ui-src', 'panel.mjs')],
  bundle: true, platform: 'browser', format: 'iife', target: 'es2022', sourcemap: false, logLevel: 'info', write: false,
});
const page = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cua-rdp child desktop</title>
<style>
:root { color-scheme: light dark; font-family: system-ui, "Segoe UI", "Microsoft YaHei", sans-serif; }
body { margin: 0; padding: 12px; font-size: 13px; line-height: 1.5; }
h1 { font-size: 15px; margin: 0 0 2px; }
h2 { font-size: 13px; margin: 10px 0 4px; }
.subtitle { margin: 0 0 10px; opacity: .75; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-weight: 600; margin-bottom: 8px; }
.badge[data-state="ready"] { background: #1a7f37; color: #fff; }
.badge[data-state="stopped"] { background: #57606a; color: #fff; }
.badge[data-state="needs-authentication"], .badge[data-state="failed"], .badge[data-state="authenticating"] { background: #9a6700; color: #fff; }
.details { display: grid; grid-template-columns: auto 1fr; gap: 2px 10px; margin: 0 0 8px; }
.details dt { opacity: .7; }
.details dd { margin: 0; font-family: ui-monospace, Consolas, monospace; overflow-wrap: anywhere; }
.error { border-left: 3px solid #cf222e; padding: 6px 8px; margin: 8px 0; background: rgba(207,34,46,.08); overflow-wrap: anywhere; white-space: pre-wrap; }
.hint { margin-top: 6px; opacity: .85; }
.notice { border-left: 3px solid #0969da; padding: 6px 8px; margin: 8px 0; background: rgba(9,105,218,.08); }
.actions { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
button { padding: 5px 10px; border-radius: 6px; border: 1px solid rgba(127,127,127,.45); cursor: pointer; font: inherit; }
button:disabled { opacity: .45; cursor: default; }
button.primary { background: #1f6feb; border-color: #1f6feb; color: #fff; }
button.danger { background: transparent; border-color: #cf222e; color: #cf222e; }
.takeover { border: 1px solid rgba(127,127,127,.35); border-radius: 8px; padding: 8px 10px; margin-top: 8px; }
.example { margin: 6px 0 0; padding: 6px 8px; background: rgba(127,127,127,.12); border-radius: 6px; font-family: ui-monospace, Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
.footnote { margin-top: 10px; opacity: .65; }
.hidden { display: none; }
html[data-theme="dark"] body { color: #e6edf3; }
</style>
</head>
<body>
<div id="panel"></div>
<script>
${panel.outputFiles[0].text}
</script>
</body>
</html>
`;
await mkdir(path.join(ROOT, 'ui'), { recursive: true });
await writeFile(path.join(ROOT, 'ui', 'panel.html'), page);
