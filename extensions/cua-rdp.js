// Pi package entry point for cua-rdp.
//
// A Pi package cannot ship MCP server configuration, so the bundled stdio MCP server
// that Codex and Claude Code load from this repository's manifests is registered here
// instead. Everything else (the `desktop` skill, the Windows runtime scripts and the
// bundles under dist/) is shared with those clients.
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** This file lives in `<package>/extensions/`, so the package root is one level up. */
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const serverPath = join(packageRoot, "dist", "desktop-server.mjs");
const doctorPath = join(packageRoot, "src", "cli.mjs");

// `process.execPath` is Node itself for every supported install (the npm launcher or a
// direct `node dist/bundle/cli.js` run). A standalone Pi binary would be handed a script
// it cannot run, so fall back to `node` on PATH; cua-rdp requires Node.js 22+ anyway.
const nodeCommand = /^node(\.exe)?$/iu.test(basename(process.execPath)) ? process.execPath : "node";

/**
 * @param {import("@earendil-works/pi-coding-agent").ExtensionAPI} pi
 */
export default function cuaRdp(pi) {
  pi.registerMcpServer("cua-rdp", {
    type: "stdio",
    command: nodeCommand,
    args: [serverPath],
    // The seven desktop_* tools are a small task-oriented set that the desktop skill
    // calls by name, so they are declared like Codex and Claude Code declare them.
    exposure: "direct",
    // Interactive authentication may wait up to 330 s for the Windows logon window and a
    // guest call may take up to 360 s. The server sends no progress notifications, so the
    // per-request timeout has to cover the whole call.
    timeout: 420,
    description: "Operate a separate Windows desktop with cua-driver in a verified RDP Child Session.",
  });

  pi.registerCommand("cua-rdp-doctor", {
    description: "Check cua-rdp host prerequisites (read-only, never creates a desktop)",
    handler: async (_args, ctx) => {
      const result = await pi.exec(nodeCommand, [doctorPath, "doctor"], { timeout: 180_000 });
      const report = formatDoctor(result);
      if (ctx.hasUI) ctx.ui.notify(report.text, report.ok ? "info" : "warning");
      else process.stdout.write(`${report.text}\n`);
    },
  });
}

/** Turn the doctor command's JSON report into a short transcript/notification. */
function formatDoctor(result) {
  let parsed;
  try { parsed = JSON.parse(result.stdout); }
  catch { parsed = undefined; }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    const detail = [result.stderr, result.stdout].map(value => String(value).trim()).filter(Boolean).join("\n").slice(0, 2000);
    return {
      ok: false,
      text: `cua-rdp doctor exited with code ${result.code}${result.killed ? " (timed out)" : ""}${detail ? `:\n${detail}` : ""}`,
    };
  }
  const lines = [`cua-rdp doctor: ${parsed.ok ? "ok" : "blocked"} (backend: ${parsed.backend ?? "unknown"})`];
  for (const check of Array.isArray(parsed.checks) ? parsed.checks : []) {
    const detail = check?.detail === undefined ? "" : ` - ${typeof check.detail === "string" ? check.detail : JSON.stringify(check.detail)}`;
    lines.push(`${check?.ok ? "[ok]" : "[!!]"} ${check?.name ?? "check"}${detail}`);
  }
  if (parsed.ok !== true && Array.isArray(parsed.prerequisites)) {
    lines.push("Prerequisites:", ...parsed.prerequisites.map(item => `- ${item}`));
  }
  return { ok: parsed.ok === true, text: lines.join("\n").slice(0, 6000) };
}
