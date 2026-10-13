using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32;

namespace CuaRdp.Native
{
    public sealed class ChildSessionState
    {
        public bool enabled { get; set; }
        public int parentSessionId { get; set; }
        public string parentLogonTime { get; set; }
        public int parentState { get; set; }
        public int parentProtocol { get; set; }
        public int? activeConsoleSessionId { get; set; }
        public bool isConsoleParent { get; set; }
        public string userSid { get; set; }
        public string machineGuid { get; set; }
        public int? childSessionId { get; set; }
        public string childLogonTime { get; set; }
        public int? childState { get; set; }
        public int? childProtocol { get; set; }
        public string childUserSid { get; set; }
        public int rdpPort { get; set; }
        public bool rdpWrapper { get; set; }
        public bool elevated { get; set; }
    }

    public sealed class ChildSessionExpectation
    {
        public int ParentSessionId { get; private set; }
        public string ParentLogonTime { get; private set; }
        public int? ChildSessionId { get; private set; }
        public string ChildLogonTime { get; private set; }

        public ChildSessionExpectation(int parentSessionId, string parentLogonTime, int? childSessionId, string childLogonTime)
        {
            if (parentSessionId <= 0) throw new ArgumentException("The expected parent session must not be Session 0.");
            ChildSessionGuard.ValidateLogonTime(parentLogonTime);
            if (childSessionId.HasValue)
            {
                if (childSessionId.Value <= 0 || childSessionId.Value == parentSessionId)
                    throw new ArgumentException("The expected child session ID is invalid.");
                ChildSessionGuard.ValidateLogonTime(childLogonTime);
            }
            else if (!String.IsNullOrEmpty(childLogonTime))
                throw new ArgumentException("A child logon generation requires a child session ID.");
            ParentSessionId = parentSessionId;
            ParentLogonTime = parentLogonTime;
            ChildSessionId = childSessionId;
            ChildLogonTime = childLogonTime;
        }
    }

    public static class ChildSessionGuard
    {
        public static void ValidateLogonTime(string value)
        {
            long parsed;
            if (value == null || !Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) ||
                parsed <= 0 || parsed.ToString(CultureInfo.InvariantCulture) != value)
                throw new InvalidOperationException("A session logon generation must be a positive decimal FILETIME string.");
        }

        private static void ValidateParent(ChildSessionState snapshot, ChildSessionExpectation expected, int port)
        {
            if (snapshot == null || expected == null) throw new ArgumentNullException("snapshot/expected");
            if (!snapshot.enabled)
                throw new InvalidOperationException("Windows Child Sessions are disabled. An administrator can explicitly run native\\Enable-ChildSessions.ps1 after reviewing that system-wide change; desktop_start never enables them.");
            if (snapshot.rdpWrapper)
                throw new InvalidOperationException("RDP Wrapper is configured for TermService; native Child Sessions are not supported with RDP Wrapper.");
            if (snapshot.parentSessionId <= 0 || !snapshot.isConsoleParent || snapshot.parentState != 0 ||
                snapshot.parentProtocol != 0 || snapshot.activeConsoleSessionId != snapshot.parentSessionId)
                throw new InvalidOperationException("Child Sessions require the active local console parent in this version. Session 0, disconnected parents, and RDP/Child Session parents are not supported.");
            ValidateLogonTime(snapshot.parentLogonTime);
            if (snapshot.parentSessionId != expected.ParentSessionId || snapshot.parentLogonTime != expected.ParentLogonTime)
                throw new InvalidOperationException("The parent session identity or logon generation changed; refusing to connect.");
            if (String.IsNullOrEmpty(snapshot.userSid) || String.IsNullOrEmpty(snapshot.machineGuid))
                throw new InvalidOperationException("The current user or machine identity could not be verified.");
            if (port < 1 || port > 65535 || snapshot.rdpPort != port)
                throw new InvalidOperationException("The RDP port no longer matches the local listener configuration.");
        }

        private static void ValidateChild(ChildSessionState snapshot, int state)
        {
            if (!snapshot.childSessionId.HasValue || snapshot.childSessionId.Value <= 0 || snapshot.childSessionId == snapshot.parentSessionId)
                throw new InvalidOperationException("A distinct Windows child session could not be verified.");
            ValidateLogonTime(snapshot.childLogonTime);
            if (snapshot.childUserSid != snapshot.userSid || String.IsNullOrEmpty(snapshot.childUserSid))
                throw new InvalidOperationException("The child session belongs to a different or unverifiable Windows identity.");
            // A disconnected child session no longer reports its RDP protocol association (Windows returns 0);
            // require the RDP protocol only while the session is active.
            bool protocolMatches = state == 4 ? snapshot.childProtocol == 0 || snapshot.childProtocol == 2 : snapshot.childProtocol == 2;
            if (!protocolMatches || snapshot.childState != state)
                throw new InvalidOperationException(state == 4
                    ? "Only an exactly owned, disconnected RDP child session may be resumed; an active or foreign connection will not be taken over."
                    : "The child session is not an active RDP session.");
        }

        private static void ValidateExpectedChild(ChildSessionState snapshot, ChildSessionExpectation expected)
        {
            if (snapshot.childSessionId != expected.ChildSessionId || snapshot.childLogonTime != expected.ChildLogonTime)
                throw new InvalidOperationException("The child session ID or logon generation differs from the ownership record; refusing to adopt it.");
        }

        public static void BeforeConnect(ChildSessionState snapshot, ChildSessionExpectation expected, int port)
        {
            ValidateParent(snapshot, expected, port);
            if (!expected.ChildSessionId.HasValue)
            {
                if (snapshot.childSessionId.HasValue || snapshot.childLogonTime != null || snapshot.childState.HasValue ||
                    snapshot.childProtocol.HasValue || snapshot.childUserSid != null)
                    throw new InvalidOperationException("A child session already exists without a matching ownership record; it will not be adopted or disconnected.");
                return;
            }
            ValidateChild(snapshot, 4);
            ValidateExpectedChild(snapshot, expected);
        }

        public static ChildSessionExpectation AfterLogin(ChildSessionState snapshot, ChildSessionExpectation expected, int port)
        {
            ValidateParent(snapshot, expected, port);
            ValidateChild(snapshot, 0);
            if (expected.ChildSessionId.HasValue) ValidateExpectedChild(snapshot, expected);
            return new ChildSessionExpectation(snapshot.parentSessionId, snapshot.parentLogonTime, snapshot.childSessionId, snapshot.childLogonTime);
        }

        public static void WhileConnected(ChildSessionState snapshot, ChildSessionExpectation bound, int port, string userSid, string machineGuid)
        {
            if (bound == null || !bound.ChildSessionId.HasValue)
                throw new InvalidOperationException("No child session identity has been bound to this connection.");
            ValidateParent(snapshot, bound, port);
            ValidateChild(snapshot, 0);
            ValidateExpectedChild(snapshot, bound);
            if (snapshot.userSid != userSid || snapshot.machineGuid != machineGuid)
                throw new InvalidOperationException("The child connection's user or machine identity changed.");
        }
    }

    public sealed class ChildSessionControllerLease : IDisposable
    {
        private Mutex mutex;
        private bool held;

        private ChildSessionControllerLease() { }

        public static ChildSessionControllerLease Acquire(bool selfTest)
        {
            var result = new ChildSessionControllerLease();
            try
            {
                // A single machine-wide name also fails closed when another user's ACL denies access.
                result.mutex = new Mutex(false, selfTest ? "Global\\CuaRdp.ChildSession.SelfTest.v2" : "Global\\CuaRdp.ChildSession.Controller.v2");
                try { result.held = result.mutex.WaitOne(0); }
                catch (AbandonedMutexException)
                {
                    result.held = true;
                    throw new InvalidOperationException("A previous Child Session controller ended abnormally; re-check session ownership before retrying.");
                }
                if (!result.held) throw new InvalidOperationException("Another CuaRdp Child Session controller is already running on this machine.");
                return result;
            }
            catch { result.Dispose(); throw; }
        }

        public void Dispose()
        {
            if (mutex == null) return;
            try { if (held) { mutex.ReleaseMutex(); held = false; } }
            finally { mutex.Dispose(); mutex = null; }
        }
    }

    public static class ChildSessionNative
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 8)]
        private struct WtsInfo
        {
            public int State;
            public uint SessionId;
            public uint IncomingBytes, OutgoingBytes, IncomingFrames, OutgoingFrames;
            public uint IncomingCompressedBytes, OutgoingCompressedBytes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
            public long ConnectTime, DisconnectTime, LastInputTime, LogonTime, CurrentTime;
        }

        private sealed class SessionIdentity
        {
            public int Id;
            public int State;
            public int Protocol;
            public string LogonTime;
            public string Sid;
        }

        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSIsChildSessionsEnabled([MarshalAs(UnmanagedType.Bool)] out bool enabled);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSGetChildSessionId(out uint sessionId);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSEnableChildSessions([MarshalAs(UnmanagedType.Bool)] bool enabled);
        [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSQuerySessionInformation(IntPtr server, uint sessionId, int informationClass, out IntPtr buffer, out uint bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        [DllImport("kernel32.dll")]
        private static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetTokenInformation(IntPtr token, int informationClass, out int information, int length, out int returnedLength);

        public static int WtsInfoSize { get { return Marshal.SizeOf(typeof(WtsInfo)); } }
        public static int LogonTimeOffset { get { return Marshal.OffsetOf(typeof(WtsInfo), "LogonTime").ToInt32(); } }

        public static void ValidateLayout()
        {
            if (WtsInfoSize != 216 || LogonTimeOffset != 200)
                throw new InvalidOperationException("The WTSINFOW ABI is not supported: expected 216 bytes and LogonTime offset 200.");
        }

        public static bool IsEnabled()
        {
            bool enabled;
            if (!WTSIsChildSessionsEnabled(out enabled))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSIsChildSessionsEnabled failed.");
            return enabled;
        }

        public static void Enable()
        {
            if (!WTSEnableChildSessions(true))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSEnableChildSessions(true) failed. Run the explicit enable helper as an administrator.");
        }

        public static int? DecodeChildSessionId(bool success, uint id, int errorCode)
        {
            if (!success)
            {
                if (errorCode == 1168) return null; // ERROR_NOT_FOUND is also returned on Windows builds without a child.
                throw new Win32Exception(errorCode, "WTSGetChildSessionId failed; an unknown session is not treated as absent.");
            }
            if (id == UInt32.MaxValue) return null;
            if (id == 0 || id > Int32.MaxValue) throw new InvalidOperationException("Windows returned an invalid child session ID.");
            return (int)id;
        }

        private static int? GetChildId()
        {
            uint id;
            bool success = WTSGetChildSessionId(out id);
            int error = Marshal.GetLastWin32Error();
            return DecodeChildSessionId(success, id, error);
        }

        private static IntPtr Query(uint id, int informationClass, out uint bytes)
        {
            IntPtr buffer;
            if (!WTSQuerySessionInformation(IntPtr.Zero, id, informationClass, out buffer, out bytes))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSQuerySessionInformation failed for session " + id + ", class " + informationClass + ".");
            if (buffer == IntPtr.Zero) throw new InvalidOperationException("WTS returned a null session-information buffer.");
            return buffer;
        }

        private static WtsInfo QueryInfo(uint id)
        {
            uint bytes;
            IntPtr buffer = Query(id, 24, out bytes);
            try
            {
                if (bytes < WtsInfoSize) throw new InvalidOperationException("WTS returned a truncated WTSINFOW structure.");
                var info = (WtsInfo)Marshal.PtrToStructure(buffer, typeof(WtsInfo));
                if (info.SessionId != id || info.State < 0 || info.State > 9 || info.LogonTime <= 0)
                    throw new InvalidOperationException("WTS session identity or logon generation could not be verified.");
                return info;
            }
            finally { WTSFreeMemory(buffer); }
        }

        private static string QueryString(uint id, int informationClass)
        {
            uint bytes;
            IntPtr buffer = Query(id, informationClass, out bytes);
            try
            {
                if (bytes < 2 || bytes > 65536 || (bytes & 1) != 0 || Marshal.ReadInt16(buffer, (int)bytes - 2) != 0)
                    throw new InvalidOperationException("WTS returned an invalid identity string.");
                return Marshal.PtrToStringUni(buffer, (int)bytes / 2 - 1).TrimEnd('\0');
            }
            finally { WTSFreeMemory(buffer); }
        }

        private static SessionIdentity ReadSession(int sessionId)
        {
            uint id = checked((uint)sessionId);
            WtsInfo info = QueryInfo(id);
            uint bytes;
            IntPtr buffer = Query(id, 16, out bytes);
            int protocol;
            try
            {
                if (bytes < 2) throw new InvalidOperationException("WTS returned a truncated protocol value.");
                protocol = (ushort)Marshal.ReadInt16(buffer);
            }
            finally { WTSFreeMemory(buffer); }
            // WTSINFO's fixed username field can be truncated; use the full identity queries for SID lookup.
            string user = QueryString(id, 5);
            string domain = QueryString(id, 7);
            if (String.IsNullOrEmpty(user) || String.IsNullOrEmpty(domain))
                throw new InvalidOperationException("WTS did not return a complete user identity for session " + id + ".");
            string sid = ((SecurityIdentifier)new NTAccount(domain, user).Translate(typeof(SecurityIdentifier))).Value;
            WtsInfo after = QueryInfo(id);
            if (after.LogonTime != info.LogonTime || after.State != info.State)
                throw new InvalidOperationException("The session changed while its identity was being read.");
            return new SessionIdentity {
                Id = sessionId, State = info.State, Protocol = protocol,
                LogonTime = info.LogonTime.ToString(CultureInfo.InvariantCulture), Sid = sid
            };
        }

        private static void ReadMachine(ChildSessionState snapshot)
        {
            using (RegistryKey machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            {
                using (RegistryKey key = machine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography", false))
                {
                    object value = key == null ? null : key.GetValue("MachineGuid");
                    Guid guid;
                    if (!(value is string) || !Guid.TryParse((string)value, out guid) || guid == Guid.Empty)
                        throw new InvalidOperationException("The local MachineGuid could not be read.");
                    snapshot.machineGuid = (string)value;
                }
                using (RegistryKey key = machine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp", false))
                {
                    object value = key == null ? null : key.GetValue("PortNumber");
                    if (!(value is int) || (int)value < 1 || (int)value > 65535)
                        throw new InvalidOperationException("The local RDP listener port could not be read.");
                    snapshot.rdpPort = (int)value;
                }
                using (RegistryKey key = machine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\TermService\Parameters", false))
                {
                    object value = key == null ? null : key.GetValue("ServiceDll", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (!(value is string) || String.IsNullOrEmpty((string)value))
                        throw new InvalidOperationException("The TermService module configuration could not be read.");
                    snapshot.rdpWrapper = ((string)value).IndexOf("rdpwrap", StringComparison.OrdinalIgnoreCase) >= 0;
                }
            }
        }

        public static ChildSessionState Capture()
        {
            ValidateLayout();
            var snapshot = new ChildSessionState();
            snapshot.enabled = IsEnabled();
            int parentId;
            using (Process current = Process.GetCurrentProcess()) parentId = current.SessionId;
            SessionIdentity parent = ReadSession(parentId);
            snapshot.parentSessionId = parent.Id;
            snapshot.parentLogonTime = parent.LogonTime;
            snapshot.parentState = parent.State;
            snapshot.parentProtocol = parent.Protocol;
            uint consoleId = WTSGetActiveConsoleSessionId();
            snapshot.activeConsoleSessionId = consoleId == UInt32.MaxValue ? (int?)null : checked((int)consoleId);
            snapshot.isConsoleParent = parent.Id > 0 && snapshot.activeConsoleSessionId == parent.Id && parent.State == 0 && parent.Protocol == 0;
            using (WindowsIdentity current = WindowsIdentity.GetCurrent())
            {
                if (current.User == null || current.User.Value != parent.Sid)
                    throw new InvalidOperationException("The process identity differs from its Windows session owner.");
                snapshot.userSid = current.User.Value;
                int elevated, bytes;
                if (!GetTokenInformation(current.Token, 20, out elevated, sizeof(int), out bytes) || bytes != sizeof(int))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading process token elevation failed.");
                snapshot.elevated = elevated != 0;
            }
            ReadMachine(snapshot);
            snapshot.childSessionId = GetChildId();
            if (snapshot.childSessionId.HasValue)
            {
                SessionIdentity child = ReadSession(snapshot.childSessionId.Value);
                snapshot.childLogonTime = child.LogonTime;
                snapshot.childState = child.State;
                snapshot.childProtocol = child.Protocol;
                snapshot.childUserSid = child.Sid;
            }
            if (GetChildId() != snapshot.childSessionId)
                throw new InvalidOperationException("The child session association changed while it was being read.");
            WtsInfo parentAfter = QueryInfo(checked((uint)parentId));
            if (parentAfter.LogonTime.ToString(CultureInfo.InvariantCulture) != parent.LogonTime || parentAfter.State != parent.State ||
                WTSGetActiveConsoleSessionId() != consoleId)
                throw new InvalidOperationException("The parent session changed while it was being read.");
            return snapshot;
        }
    }
}
