# Native RDP keeper

The keeper owns a transient Windows job and its RDP ActiveX worker. Child Session mode hosts on **Default**, off-screen with no-activate/tool-window styles during background operation; Hyper-V mode uses a private Win32 desktop. Neither mode switches the input desktop, injects host input, registers tasks/services/startup entries, changes firewall rules, patches Windows, or logs off sessions.

## Discovery and ownership

```powershell
powershell.exe -NoProfile -NonInteractive -File native/Get-ChildSessionState.ps1
```

The UTF-8 JSON snapshot includes feature enablement, parent/child SessionIds, logon generations, WTS states/protocols, user SIDs, MachineGuid, active console ID, listener port, RDP Wrapper indication and elevation. Registry/WTS access is read-only.

Logon generations are decimal FILETIME **strings**, not floating-point numbers. WTSSessionInfo (24) uses Unicode WTSINFOW with 32/17/21-character arrays, size 216 and LogonTime at offset 200. Failed generation/identity queries fail closed. Only WTSGetChildSessionId success with ULONG_MAX or ERROR_NOT_FOUND (1168) means absent; other errors propagate. Capture rechecks generations and association to reject mid-read changes.

Only a nonzero active local console parent is supported (state 0, protocol 0, matching active console ID). Session 0, ordinary RDP parents, nested children and disconnected parents are refused. A fresh connection requires no child. Resume requires the exact saved machine/SID/parent+child IDs **and generations**, same child user, and disconnected state 4/protocol 0 or 2. Active/heartbeat checks require state 0/protocol 2. Foreign or active children are not adopted.

The native keeper holds Global\CuaRdp.ChildSession.Controller.v2 until its owned worker exits. Contention, denied access and abandoned mutexes fail closed. Self-tests use a separate mutex. The owner PID must belong to the expected parent. Guards run in the launcher, worker, immediately before Connect, after OnLoginComplete, and on connected timer ticks. Windows ends a child when its parent logs off; the plugin does not call WTSLogoffSession.

Feature enablement is separate and explicit: native/Enable-ChildSessions.ps1 supports -WhatIf and high-impact ShouldProcess confirmation around WTSEnableChildSessions(true). Normal startup and tests never enable it.

## Keeper request

```powershell
powershell.exe -NoProfile -NonInteractive -File native/Start-RdpKeeper.ps1 -RequestPath C:\private\run\rdp.json -ParentPid 1234
```

Use a fresh private directory and retain a protected ownership record outside the keeper. A fresh child request is:

```json
{
  "mode": "child-session",
  "authentication": "background",
  "expectedParentSessionId": 1,
  "expectedParentLogonTime": "134362541354702428",
  "expectedChildSessionId": null,
  "expectedChildLogonTime": null,
  "address": "localhost",
  "port": 3389,
  "width": 1600,
  "height": 900,
  "guestRoot": "C:\Users\Example\AppData\Local\CuaRdp\child",
  "statusPath": "C:\private\run\rdp-status.json",
  "stopPath": "C:\private\run\rdp.stop",
  "bootstrapPath": "C:\private\run\bootstrap.json"
}
```

Child mode forbids credentialPath/password/userName/domain. ConnectToChildSession=true is set and read back before Connect; this is Windows' special Child Session path, not normal localhost RDP.

Absent mode preserves legacy Hyper-V behavior; explicit mode:hyperv is accepted. Supply a verified guest address and a same-user/same-machine DPAPI Export-Clixml PSCredential file. Remote mode imports its password only in the private-desktop worker, sets ConnectToChildSession=false, and refuses host/loopback/unspecified/mixed or IPv6 destinations. The caller additionally binds the address and authenticated agent identity to the chosen VM.

Child guestRoot is required and at most 160 characters. Remote mode defaults to C:\ProgramData\CuaRdp and permits 200 characters. Both require safe absolute ASCII local drive paths, rejecting traversal, empty/ambiguous components, metacharacters, spaces and Windows device names (the fixed keyboard bootstrap types the path unquoted).

## Authentication

- **background (default)**: no visible logon window, credential prompts disabled, AuthenticationLevel=1 and NLA/CredSSP enabled. Authentication warnings fail closed; other disconnects keep their real reason without diagnosing it as a certificate or Credential Guard issue.
- **interactive (child only)**: explicitly permits a visible Windows credential/certificate prompt on this connection. AuthenticationLevel=2 lets Windows warn the user; the plugin does not auto-accept keys. After logon and WTS verification, the same HWND/control remains visible for fixed agent preparation, then moves off-screen only after bootstrap.started. backgroundReady must be true before desktop_start can return ready. The transition checks HWND/COM continuity; it does not change ShowInTaskbar and recreate the control.
- Both modes disable credential saving and all clipboard/drive/printer/port/smart-card/device/dynamic-drive/dynamic-device/POS/audio redirections. No password is read by plugin code, placed in request JSON, or saved in child mode.
- Windows policy can require a password on **every connection**, including resume. A separate diagnostic login does not eliminate that requirement. Interactive authentication deliberately uses the current desktop for sign-in; it is an explicit exception, not an unattended background start.

Local tests on Insider 28120 found authentication stalled on a private desktop, hence Default hosting for child mode. This is a local observation, not a universal Windows limitation. Background code calls neither SetFocus nor SetForegroundWindow. Actual focus/cursor/clipboard invariance still requires real acceptance on the target machine.

Login deadlines (worker / launcher / Node): child background 30/40/50 seconds, child interactive 300/315/330 seconds, Hyper-V 120/130/150 seconds. Agent readiness then has a separate 90-second deadline.

## Status and lifetime

Status is atomically replaced once per second. States are connecting, authenticating (explicit interactive mode), connected, failed, stopped, or self-test-passed. Connected requires OnLoginComplete plus WTS identity checks, not merely OnConnected. Child status uses desktop:Default and includes the pinned parent/child IDs and generation strings. Failure includes error and, when specifically identified, errorCode (AUTHENTICATION_REQUIRED).

The Node reader retries ENOENT/EBUSY/EPERM for a bounded replacement race. It never caches connected state to mask persistent missing status, a stale heartbeat (>10 seconds) or an exited launcher. Only authenticated agent health makes desktop_start return ready.

The worker ends on owner exit, stop marker, disconnect or failure. Job closure terminates only its owned worker/descendants. The child/VM and other applications remain. Agent cleanup and durable ownership retention are the controller's responsibility; normal stop is not logoff.

## Remote-only bootstrap

The **Child Session backend no longer types anything** (2026-10-13). The controller stages the runtime, writes `bootstrap.json` as `{"id":<32hex>,"launch":"task"}`, and starts the staged agent through a temporary session-bound scheduled task (`scripts/child/Launch-AgentTask.ps1`); the keeper only watches for the local `runs/<id>/bootstrap.started` marker (60-second deadline) and then transitions off-screen. A keyboard bootstrap could not reliably bypass a Chinese IME — with the caps-lock upper-case scheme the Run dialog opened and submitted, but letters were still pulled into the pinyin composition window (lower-cased, fragments dropped) — so no keys are sent at all now. No focus is required or observed during bootstrap.

**Hyper-V keeps the typed bootstrap.** The controller stages the runtime, then writes bootstrap.json containing a lowercase 32-hex id and exactly:

```text
POWERSHELL.EXE -NOPROFILE -FILE <GUESTROOT>\START-AGENT.PS1 -RUNID <ID>
```

The command is upper case and unquoted on purpose: it is typed while a Caps Lock tap holds the session IME in direct-English mode, so a Chinese IME cannot pull the letters into its pinyin composition window (where Space commits candidates and Enter only commits raw text instead of submitting the dialog). Windows treats paths, exe names and PowerShell switches case-insensitively, and the guest normalizes the run ID to lower case; the only Shift-required character left is the drive colon. guestRoot must therefore be space-free.

After a five-second post-logon delay, the keeper sends Win+R, Ctrl+A, Caps Lock, the fixed upper-case command, Caps Lock (restore) and Enter **once per run ID**. All events go to IMsRdpClientNonScriptable.SendKeys; there is no parent input/focus call or automatic key replay. US English keyboard layout is requested. The client sets and read-verifies `KeyboardHookMode=1` (apply Windows-key combinations on the remote computer): with only the deprecated `EnableWindowsKey` the Win+R chord was dropped client-side, proven by a child RunMRU untouched since the previous day, no NoRun/NoWinKeys policy, no PowerShell engine start in the probe window and keeper foreground held throughout. The readback check runs in the no-connect configuration self-test.

Interactive preparation additionally checks the existing input capture and keeper foreground before each batch. Before the first Win+R, missing focus produces `bootstrapPhase:waiting-input-focus` / `inputFocusRequired:true` without marking the run attempted or sending keys. The user clicks the preparation window **title bar** and keeps it focused until it hides. Waiting is bounded by the existing 90-second agent-readiness deadline. Focus loss after the first batch fails with `RDP_INPUT_FOCUS_REQUIRED`; it never waits and resumes a partially typed command. Background/Hyper-V retain their remote-only SendKeys path without acquiring or requiring parent foreground. This conservative interactive guard is a client workflow, not a documented SendKeys focus prerequisite.

SendKeys key data is the **raw set-1 scan code layout**, not the WM_KEYDOWN lParam layout the Microsoft API page describes: bits 0..7 carry the scan code, bit 8 (0x0100) marks extended keys, and the separate VARIANT_BOOL array carries the up state (TRUE=-1). This matches the field-proven BetterGI child-session client; with the documented lParam layout every call returned S_OK while no keys reached the child session on Windows 11 28120 (2026-10-13 bisect: production settings and the 10-12 known-delivering minimal settings both failed, RunMRU untouched, no marker, no child engine start, input capture focused). The imported interface gives the exact COM slot. Contiguous VARIANT_BOOL (16-bit) and LONG (32-bit) buffers carry at most 20 events per atomic call. Complete modifier chords stay in one batch; text batches end with all modifiers released.

Only child mode checks the local runs/<id>/bootstrap.started marker, with a 60-second post-Enter deadline. Hyper-V never interprets guestRoot as a host-local marker path. bootstrapId means attempted, not ready. Missing Explorer, Run policy, keyboard layout, input channel or shell readiness can block startup; missing marker alone does not prove an authentication failure. Actual PID/session/generation, ready.json and authenticated driver health are mandatory.

## Verification

```powershell
npm run verify
# Real background connection; preserves existing sessions:
node test/probe-child-session.mjs --run
# Only with explicit permission for a visible authentication window:
node test/probe-child-session.mjs --run --interactive-authentication
```

Offline tests check the keyboard numbers, native buffer widths/limits/HRESULTs, the task-mode bootstrap request shape, real read-only WTS discovery, ownership guards, actual ActiveX property readback (including both authentication configurations), same-HWND transition, mutex exclusion and job cleanup. They never Connect, enable features, submit credentials, send keys to a real session, register a real scheduled task or log off. They are **not proof of delivered keys or a working GUI chain**.

**Real-machine acceptance (2026-10-13, Windows 11 Insider 28120) passed**: interactive authentication → task-launched bootstrap → `state: ready` → driver tool/schema/skill reads → child-desktop screen capture (1600x900) → parent focus/cursor/clipboard/input-desktop unchanged during and after the run → clean stop. The investigation that got there: background connections are server-terminated at NLA negotiation (reason 2055/0x807, no credential exchange) because this build requires an interactive password on every connection; the historical "keys delivered on 10-12, then not" split was explained when the keytest bisect showed even the known-delivering settings failed, and the delivered-but-mangled Run dialog text proved the IME interception. SendKeys keyData uses raw set-1 scan codes plus the 0x0100 extended flag (BetterGI's field-proven layout); the WM_KEYDOWN lParam layout described by the API documentation delivered nothing while every call returned S_OK.

Invoke-ChildSessionLogon.ps1 -Run now invokes the public controller's explicit interactive **probe**, then stops it; it is not a permanent-password-free setup. Experimental client-comparison prototypes are under debug/ and excluded from normal startup. Their wrapper refuses all existing children and holds the controller mutex. They do not establish production acceptance.

Failure diagnostics retain only redacted metadata under the runtime's private ACL. They exclude agent.json, owner.token, raw logs and authentication screenshots. Older pre-fix diagnostics may contain old per-run tokens; they are not automatically deleted or redistributed.

Child Session is interaction isolation, **not a security sandbox**. Parent and child share OS/user/filesystem/network/configuration; same-user programs can manipulate sessions or route single-instance IPC to the parent. Use a verified VM for untrusted code requiring a stronger boundary.

## Windows references

- [Child Sessions](https://learn.microsoft.com/windows/win32/termserv/child-sessions)
- [WTSGetChildSessionId](https://learn.microsoft.com/windows/win32/api/wtsapi32/nf-wtsapi32-wtsgetchildsessionid)
- [WTSINFOW](https://learn.microsoft.com/windows/win32/api/wtsapi32/ns-wtsapi32-wtsinfow)
- [Extended RDP properties](https://learn.microsoft.com/windows/win32/termserv/imsrdpextendedsettings-property)
- [AuthenticationLevel](https://learn.microsoft.com/windows/win32/termserv/imsrdpclientadvancedsettings4-authenticationlevel)
- [Remote-only SendKeys](https://learn.microsoft.com/windows/win32/termserv/imsrdpclientnonscriptable-sendkeys)
