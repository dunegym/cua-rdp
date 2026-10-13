[CmdletBinding()]
param([switch]$ListSessions)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if (-not ('CuaRdp.SessionInfo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace CuaRdp {
    public sealed class SessionRecord {
        public int sessionId;
        public string userSid;
        public int protocol;
        public int state;
        public string logonTime;
    }

    public static class SessionInfo {
        [StructLayout(LayoutKind.Sequential)]
        private struct WTS_SESSION_INFO {
            public int SessionId;
            public IntPtr StationName;
            public int State;
        }
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WTSQuerySessionInformationW(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr buffer, out int count);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder text, int length, out int needed);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseDesktop(IntPtr handle);

        private static int Number(int sessionId, int infoClass, bool shortValue) {
            IntPtr buffer;
            int bytes;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes)) return -1;
            try {
                if (bytes < (shortValue ? 2 : 4)) return -1;
                return shortValue ? Marshal.ReadInt16(buffer) : Marshal.ReadInt32(buffer);
            } finally { WTSFreeMemory(buffer); }
        }
        private static string Text(int sessionId, int infoClass) {
            IntPtr buffer;
            int bytes;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes)) return null;
            try { return bytes > 1 ? Marshal.PtrToStringUni(buffer) : null; }
            finally { WTSFreeMemory(buffer); }
        }
        private static SessionRecord Describe(int id) {
            string user = Text(id, 5);
            string domain = Text(id, 7);
            string sid = null;
            if (!String.IsNullOrWhiteSpace(user)) {
                try {
                    NTAccount account = String.IsNullOrWhiteSpace(domain) ? new NTAccount(user) : new NTAccount(domain, user);
                    sid = ((SecurityIdentifier)account.Translate(typeof(SecurityIdentifier))).Value;
                } catch (IdentityNotMappedException) { }
            }
            return new SessionRecord { sessionId = id, userSid = sid, protocol = Number(id, 16, true), state = Number(id, 8, false) };
        }
        private static string LogonTime(int sessionId) {
            IntPtr buffer;
            int bytes;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, 24, out buffer, out bytes)) return null;
            try {
                // WTSINFOW uses UTF-16 arrays of 32/17/21 characters and 8-byte LARGE_INTEGER alignment.
                if (bytes < 216) return null;
                long value = Marshal.ReadInt64(buffer, 200);
                return value > 0 ? value.ToString(System.Globalization.CultureInfo.InvariantCulture) : null;
            } finally { WTSFreeMemory(buffer); }
        }
        public static SessionRecord Current() {
            SessionRecord result = Describe(Process.GetCurrentProcess().SessionId);
            result.userSid = WindowsIdentity.GetCurrent().User.Value;
            result.logonTime = LogonTime(result.sessionId);
            return result;
        }
        public static SessionRecord[] All() {
            IntPtr buffer;
            int count;
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out buffer, out count))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var sessions = new List<SessionRecord>();
            try {
                int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++) {
                    var record = (WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer, i * size), typeof(WTS_SESSION_INFO));
                    sessions.Add(Describe(record.SessionId));
                }
                return sessions.ToArray();
            } finally { WTSFreeMemory(buffer); }
        }
        public static string InputDesktop() {
            IntPtr desktop = OpenInputDesktop(0, false, 0x0001);
            if (desktop == IntPtr.Zero) return null;
            try {
                var name = new StringBuilder(256);
                int needed;
                return GetUserObjectInformationW(desktop, 2, name, name.Capacity * 2, out needed) ? name.ToString() : null;
            } finally { CloseDesktop(desktop); }
        }
    }
}
'@
}

$current = [CuaRdp.SessionInfo]::Current()
$result = [ordered]@{
    machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    sessionId = $current.sessionId
    userSid = $current.userSid
    protocol = $current.protocol
    state = $current.state
    logonTime = $current.logonTime
    inputDesktop = [CuaRdp.SessionInfo]::InputDesktop()
}
if ($ListSessions) { $result.sessions = @([CuaRdp.SessionInfo]::All()) }
$result | ConvertTo-Json -Depth 6 -Compress
