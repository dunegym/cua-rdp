# Child Session backend

The v2 default is a native Windows RDP Child Session. Hyper-V v1 configurations remain supported without migration. The Child Session path uses neither ordinary localhost RDP nor VM credentials, scheduled-task persistence, services, startup registrations, firewall changes, RDP Wrapper, or system DLL patches. It uses a no-activate, off-screen ActiveX keeper on Default for child mode and a private Win32 desktop for Hyper-V. The child backend launches its agent through a one-shot, immediately deleted session-bound scheduled task (no keyboard input); Hyper-V keeps the fixed remote-only SendKeys bootstrap on its private desktop. No host keyboard injection either way.

## Configuration and module interface

```json
{
  "version": 2,
  "backend": "child-session",
  "driverPath": "C:\\Users\\Example\\AppData\\Local\\Programs\\Cua\\cua-driver\\bin\\cua-driver.exe",
  "runtimeRoot": "C:\\Users\\Example\\AppData\\Local\\CuaRdp\\child",
  "rdp": {"width": 1600, "height": 900}
}
```

Default configuration is derived read-only from LOCALAPPDATA and the standard installed cua-driver location when the default config file does not exist. An explicitly selected missing CUA_RDP_CONFIG still errors. Only space-free ASCII runtimeRoot of <=160 characters is supported by the fixed keyboard bootstrap. Driver/Node executable paths may contain Unicode. Existing v1 config implies backend `hyperv`.

Both managers expose start(options)/status/request(operation,payload)/stop/dispose/summary. Child Session accepts a per-call authentication option (background by default, interactive only with explicit user consent); Hyper-V refuses interactive mode. `DesktopManager` selects the configured backend lazily. No changes to the seven public MCP tool names. The child implementation verifies OS SessionId, SID, MachineGuid, session logon generation and the actual child-agent PID before accepting the MCP backend. Driver always runs `mcp --direct` with its existing standard permission mode.

## Native snapshot and keeper (native/)

`Get-ChildSessionState.ps1` is read-only, emits UTF-8 JSON:

```
{enabled, parentSessionId, parentLogonTime, userSid, machineGuid,
 childSessionId: null|integer, childLogonTime: null|string,
 childState: null|integer, childProtocol: null|integer, childUserSid: null|string,
 rdpPort, rdpWrapper, elevated, isConsoleParent, parentState, parentProtocol, activeConsoleSessionId}
```

Logon timestamps are decimal strings of the Windows FILETIME, never JavaScript numbers. Query `WTSINFO.LogonTime` (information class 24), with verified Windows struct sizes, and fail closed if a generation cannot be read. `WTSGetChildSessionId` refers to the current parent session; null covers the documented unsigned -1 / not-found result. Do not treat arbitrary query errors as no child. Only the active local console parent is supported: require parentState=0, parentProtocol=0 and parentSessionId=activeConsoleSessionId. Refuse Session 0, remote RDP parents and nested child sessions.

Native helper may expose an explicit standalone enable script supporting ShouldProcess (`WTSEnableChildSessions(true)` only), but the keeper/start path NEVER enables the feature implicitly. No enabling or actual RDP connections in automated tests. Setup reports the command required if disabled.

Extend keeper JSON with:

```
{mode:"child-session", expectedParentSessionId, expectedParentLogonTime,
 expectedChildSessionId:null|integer, expectedChildLogonTime:null|string,
 address:"localhost",port:<snapshot.rdpPort>, guestRoot:<runtimeRoot>,
 width,height,statusPath,stopPath,bootstrapPath}
```

In child mode, no credentialPath and no password load. Before Connect, re-check the snapshot against expected identity. A fresh request requires no existing child. A resume request requires the EXACT recorded child ID/logon generation, same current user, and disconnected state (4); otherwise refuse instead of stealing another controller's connection. Hold one named machine-wide mutex for the keeper lifetime so two plugin clients cannot connect concurrently. A pre-existing unrelated child is never attached to or logged off. Self-tests use separate test locks.

Set Server=localhost and `IMsRdpExtendedSettings.Property["ConnectToChildSession"]=true` BEFORE Connect. A visible watch window (rdp.window=visible, the default, or desktop_start window=visible) is supported after readiness in child mode: the same HWND becomes a normal window with minimize/maximize/resize chrome and a taskbar entry, applied in place with SetWindowLong because WinForms properties would recreate the HWND and kill the connection; SmartSizing scales the remote desktop when maximized or resized; minimizing or user-closing parks it in a notification-tray icon (the connection is retained until desktop_stop; the tray menu offers restore and disconnect). window=hidden keeps the off-screen no-activate keeper, and background mode shows a window only after a successful connection. Keep NLA/CredSSP enabled and redirections disabled. Background mode uses AuthenticationLevel=1, disables credential prompts and fails closed. Explicit interactive child mode uses AuthenticationLevel=2 so Windows can ask the user to judge authentication warnings; it never auto-accepts a public key. Preserve strict remote-server checks in hyperv mode. Self-test verifies the extended property against the actual COM object without Connect. Existing hyperv mode keeps its loopback prohibition. Connected status includes childSessionId and parentSessionId after OnLoginComplete and is checked on subsequent ticks. Never automatically reconnect, enable/disable Child Sessions, or call WTSLogoffSession. Root owner process death still closes the keeper/job, not the Windows session.

## Authentication and input

- Child mode hosts on Default because private-desktop authentication stalled in local tests on Insider 28120. This is not a Windows-wide guarantee. Background windows use WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW, stay outside the virtual screen and are repositioned after topology changes. No parent input/focus API is called.
- Windows Security may require a password on every connection (reported by the user). A separate login/disconnect is not a setup cure. Explicit desktop_start({authentication:"interactive"}) authenticates the same keeper connection, verifies WTS identity, keeps its existing control visible for fixed agent preparation, and moves it off-screen only after bootstrap.started. backgroundReady gates driver readiness and calls; HWND/COM-instance continuity is checked; passwords and authentication screenshots are never saved. This mode permits visible authentication, not a fully unattended start.
- OnAuthenticationWarningDisplayed is not evidence of a self-signed-certificate banner or automatic dismissal. Background mode fails with AUTHENTICATION_REQUIRED when this event is seen; other disconnects retain their actual errors without guessing a cause. Interactive mode can wait for the user, but an authenticated WTS/agent chain is still required before ready.
- Login deadlines (worker / launcher / Node): child background 30 / 40 / 50 seconds; child interactive 300 / 315 / 330 seconds; Hyper-V 120 / 130 / 150 seconds. Agent readiness has a separate 90-second deadline.
- Disconnected child sessions reported protocol 0 locally: resume permits 0 or 2 with state 4; active checks require protocol 2/state 0.
- The client sets and read-verifies `KeyboardHookMode=1` before Connect so real keyboard chords reach the remote session; this no longer affects bootstrap (see below) but keeps manual interaction working.
- SendKeys plKeyData uses the raw set-1 scan-code layout proven in the field (scan code in bits 0..7, 0x0100 extended flag, up state in the separate 16-bit VARIANT_BOOL array), not the WM_KEYDOWN lParam layout the API documentation claims — the lParam layout delivered no keys on Windows 11 28120 while every call returned S_OK. Native arrays are contiguous 16-bit VARIANT_BOOL and 32-bit LONG values, using the imported interface's vtable slot. TRUE means release. Each atomic call has at most 20 strokes; modifiers are not split across batches. Only Hyper-V uses this path in production.
- **Child Session bootstrap is keyboard-free** (2026-10-13). A keyboard bootstrap cannot reliably bypass a Chinese IME: with the caps-lock upper-case scheme the Run dialog opened and submitted, but letters were still pulled into the pinyin composition window (lower-cased, fragments dropped; only digits and unshifted punctuation survived). The controller instead writes `bootstrap.json` as `{"id":<32hex>,"launch":"task"}` and runs `scripts/child/Launch-AgentTask.ps1 -ChildSessionId <id> -RuntimeRoot <root> -RunId <id>`, which registers a temporary scheduled task bound to the child session (current user, interactive token, least privilege, `RunEx` with the session id, `ExecutionTimeLimit PT0S`) and deletes it right after launch. The keeper sees the task-mode request, skips all key sending, watches the local `runs/<id>/bootstrap.started` marker for up to 60 seconds and then transitions off-screen exactly as before. Start-Agent still writes the marker and re-verifies the session identity; a policy that blocks task registration is a clear, reported blocker. The Hyper-V bootstrap keeps the fixed upper-case command (typed through the scan-code SendKeys path; runtimeRoot stays space-free for it).

The production chain passed full real-machine acceptance on 2026-10-13 (Windows 11 Insider 28120): interactive authentication, task-launched bootstrap, `state: ready`, driver tool/schema/skill reads, a child-desktop screen capture (1600x900) and unchanged parent focus/cursor/clipboard/input-desktop during and after the run. Two root causes were fixed to get there: the SendKeys keyData encoding (documented WM_KEYDOWN lParam vs the raw set-1 scan codes the client actually expects; the lParam layout silently delivered nothing) and the IME-defeating keyboard bootstrap (replaced by the one-shot session-bound task). Background mode remains unavailable on this Insider build: every connection requires an interactive password, and prompt-free connections are server-terminated at NLA negotiation (disconnect 2055/0x807 before any credential exchange).

## Local runtime scripts (scripts/child/)

`Initialize-Runtime.ps1 -RuntimeRoot -PluginRoot -DriverPath -NodePath` installs only our three files (dist/guest-agent.cjs, guest/Get-InteractiveState.ps1, guest/Start-Agent.ps1) plus guest-config.json under a current-user/SYSTEM/Administrators-only ACL. Checks paths/reparse points/ownership marker, and refuses changes while a run exists. Only private application files are written; no system configuration is changed.

`Get-AgentProcess.ps1 -ProcessId` reads actual process identity and returns `{pid,sessionId,startedAt}` (startedAt as invariant UTC ISO string). Access/query failures are errors, not a success. It does not launch or kill anything.

`Stop-Agent.ps1 -RuntimeRoot -RunId` receives one stdin JSON line `{token}`; there is no token command-line parameter. It writes only the owned run's stop.requested marker, then verifies process exit using bootstrap.lock + startup/ready identity and known config command line. It never kills or logs off anything. Returns `{stopped:true,retained:false}` only when the run folder was safely removed; otherwise `{stopped:false,retained:true}`. Parent closes keeper BEFORE stop. Keep lease semantics as existing guest agent. Bound wait to 10s. Validate token ownership and all paths; never delete unknown files/directories. Use no plan/task scheduling.

`Launch-AgentTask.ps1 -ChildSessionId -RuntimeRoot -RunId` is the keyboard-free bootstrap (above). It validates the runtime owner, the staged run (owner.token + agent.json with `expectedSessionId == ChildSessionId`) and Start-Agent.ps1 presence before touching the scheduler, registers the one-shot least-privilege task under a random `CuaRdp-ChildSession-Agent-<guid>` name, `RunEx`-es it bound to the child session and deletes it in `finally`. It stores no credential, writes no persistence and its failure paths are covered offline; offline tests never register a real task.

The Node backend stages `<runtimeRoot>/runs/<runId>/agent.json` and owner.token, and uses the existing Start-Agent bootstrap. guest-config.json remains `{version:1,nodePath,driverPath,userSid}`. Agent config also carries `expectedSessionLogonTime` for this backend; Get-InteractiveState returns `logonTime` and service checks it when present. Shared guest files may be updated by parent only.

## Ownership and stop

A per-user file lock prevents duplicate plugin controllers; the native machine-wide mutex handles live cross-session plugin controllers. Persist a protected owner record containing machineGuid, userSid, parentSessionId/parentLogonTime, childSessionId/childLogonTime. Only an exact matching disconnected child may be resumed. Session ID reuse or an active connection belonging to another program is an error. No foreign-session adoption and no stale lock theft.

Normal desktop_stop stops our agent/driver and disconnects our RDP keeper, leaving applications and the child session intact. It does NOT log off the child. A subsequent start may resume the exact owned disconnected session. If the parent session ends, Windows ends its child. Another application can independently manipulate the same-user session; this is interactive-session isolation, NOT a security sandbox.

Read-only checks and mocked/session-safe tests first. A real Child Session test is separate and must not close an existing session or enable system features without explicit approval. Report clearly whether actual login/capture/input were verified.

Failure diagnostics retain only redacted metadata in `<runtimeRoot>/diagnostics/<runId>/failure.json`, inheriting the runtime private ACL. Raw agent.json, owner.token, logs and authentication screenshots are excluded. Partial staging cleanup validates ordinary files, exact temporary names and owned content prefixes before unlink/rmdir; unknown contents retain the controller lock.

Bootstrap status carries backgroundReady, bootstrapPhase, inputFocusRequired and read-only input observations (COM Connected, own-control visibility, focus relationship and input-capture presence). It records no window text, key data, password or screenshot. SendKeys failures preserve RDP_INPUT_FAILED and the exact open-run/select-command/type-command/submit-command stage; input is never replayed. The probe reports a missing background baseline as not-established, not as a desktop change.
