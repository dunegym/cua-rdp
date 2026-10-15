# Codex plugin

CUA RDP packages its desktop skill and local stdio MCP server as a Windows-only Codex plugin. The root `plugin.json` uses the portable Agent Plugins schema; Codex discovers `mcp.json` and the shared `skills/` directory automatically. Codex's MCP configuration uses `${PLUGIN_ROOT}`; Claude Code continues to use `.claude-plugin/` and `.mcp.json` with `${CLAUDE_PLUGIN_ROOT}`, pointing to the same bundled server and skill.

The portable manifest is required for this package's Codex MCP wiring. On Codex CLI 0.162.1, a compatibility-only `.codex-plugin/plugin.json` loaded the skill but passed MCP path placeholders literally. The root portable manifest correctly resolves the cached server path; both skill discovery and all seven tools were verified with that layout.

## Install from a checkout

Use Windows with Node.js 22+, Windows PowerShell 5.1, the system RDP ActiveX control, and a local cua-driver 0.34.0+ installation. Run Codex from the active local console session. System prerequisites and optional driver/configuration overrides are described in [README](../README.md).

The checked-in bundles contain the server's npm dependencies. A normal install does not need `npm ci`; after editing source code, developers run `npm ci` and `npm run build` before installing.

With Codex CLI 0.162.1 or newer exposing `codex plugin add`, run from the plugin root:

```powershell
codex plugin marketplace add .
codex plugin add cua-rdp@cua-rdp
codex plugin list --marketplace cua-rdp --json
```

Alternatively, in the desktop app's plugin directory, add this local repository as a marketplace source and install **CUA RDP**. The catalog is `.agents/plugins/marketplace.json`; its `./` source resolves to the repository root. Start a new session after installation. CLI installs and desktop-app installs use cached copies, so source edits require a refresh/reinstall before testing again.

These commands change the user's plugin configuration. They do not enable Child Sessions, connect RDP, register an agent task, or modify Windows policy. Avoid configuring a second standalone MCP server for the same plugin: each controller competes for the same owned session lock.

## Use

Select the installed plugin's `desktop` skill, or mention CUA RDP in a request:

- "Use CUA RDP to check the desktop status."
- "Use CUA RDP to start the child desktop. I allow a visible Windows authentication window."
- "Use CUA RDP to open Notepad in the child desktop, type a test line, verify it, then stop."
- "Use CUA RDP to stop the desktop connection."

The `desktop` MCP server exposes the seven `desktop_*` tools documented in the README. Codex may prefix their names with a plugin namespace. Only `desktop_start` returning `state: ready` permits computer operations; `desktop_status` is read-only and creates no desktop. Credentials are entered directly into Windows. A Child Session shares the parent user's filesystem and network; it is interaction isolation, not a security sandbox.

The bundled Claude Code `agents/rdp-operator.md` is not a Codex agent registration. Codex follows the shared desktop skill directly.

## Build a distributable ZIP

```powershell
npm ci
npm run package:plugin
```

This builds both bundles and creates `dist/cua-rdp-0.4.4.zip`, containing one `cua-rdp/` plugin directory. The package includes the manifests, marketplace catalogs, skill, Pi extension, Windows runtime scripts, native sources and documentation; it excludes node_modules, Git data, local settings, tests and diagnostic prototypes. Extract it and add the extracted `cua-rdp` directory as a local marketplace with the commands above, or as a local Pi package with `pi install ./cua-rdp`. No global install or publication occurs during packaging.

## Validation

```powershell
npm run build
npm run check
npm test
```

The plugin packaging test copies the distribution files to a fresh temporary directory without node_modules, launches the actual bundled server, performs an MCP handshake, lists its tools, and checks status plus fail-closed handling of a missing explicit config. These checks never connect to RDP. `npm run verify` additionally runs the existing Windows/ActiveX checks and Claude Code manifest validation.

Plugin discovery and installation can also be checked with an isolated `CODEX_HOME` rather than changing the normal user profile. Real authentication, capture and GUI input remain separate acceptance tests; see the README probes and obtain permission for any visible Windows sign-in.

Format references: [OpenAI plugin packaging](https://developers.openai.com/plugins/build/plugins) and [local MCP requirements](https://developers.openai.com/plugins/deploy/desktop-only). This project uses a local Windows MCP server; it does not provide a cloud/web endpoint.
