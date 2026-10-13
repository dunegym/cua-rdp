# Experimental connection harness

These prototypes compare ActiveX clients/settings. They are **not** plugin startup, authentication setup, or an acceptance test. Some experimental flavors deliberately alter client-side settings. No finding from them establishes a Windows-wide guarantee.

The wrapper requires `-Run`, holds the plugin's global mutex, and refuses every existing child by default. It never enables features or logs off sessions. It may leave a newly created, disconnected child that the plugin will refuse to adopt. Authentication prompts are not captured.

## Client-settings keytest (2026-10-13 delivery bisect)

`-SecurityFlavor keytest -ClientSettings <variant> [-OwnedChild -Bisect]` runs the production caps-lock bootstrap choreography (Win+R, Ctrl+A, Caps Lock, upper-case `CMD.EXE /C COPY NUL <marker>`, Caps Lock, Enter) and judges success solely by whether the marker file appears. After every attempt the wrapper prints the RunMRU write time and entries, which distinguishes "nothing reached the child" (no MRU write) from "submitted but mangled" (new MRU entry).

Variants: `minimal` (the 2026-10-12 known-delivering settings: AudioRedirectionMode 2 + KeyboardHookMode 1), `production` (clone of the keeper's child-mode settings), `production-nolayout` / `production-nowek` / `production-clean` (production minus KeyBoardLayoutStr / EnableWindowsKey / both).

With `-OwnedChild`, the wrapper may resume **only** the exact child recorded in the plugin's durable owner record (machine/user/parent/child IDs and both FILETIME generations must match and the child must be disconnected state 4); everything else is refused exactly as before. `-Bisect` chains production → production-clean → minimal, stopping at the first passing variant. Each connection asks for the Windows password; only the user enters it. The connection disconnects after each attempt; nothing is logged off.

Use the public controller instead for acceptance:

```powershell
node test/probe-child-session.mjs --run
# Only when a visible Windows logon window is explicitly wanted:
node test/probe-child-session.mjs --run --interactive-authentication
```

The interactive controller authenticates and bootstraps on the same connection. A separate diagnostic login cannot guarantee that a later connection will not ask for a password.
