using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CuaRdp.Native
{
    public sealed class DesktopProcess : IDisposable
    {
        private IntPtr desktop;
        private IntPtr job;
        private IntPtr process;
        public int ProcessId { get; private set; }
        public string DesktopName { get; private set; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute;
            public int dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr attributes);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseDesktop(IntPtr handle);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetThreadDesktop(uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder info, int length, out int needed);
        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private DesktopProcess() { }

        public static DesktopProcess Start(string executable, string[] arguments)
        {
            return StartInternal(executable, arguments, true);
        }

        // Child mode hosts on the caller's desktop after private-desktop authentication stalled in local tests;
        // this variant keeps the kill-on-close job but creates no private desktop.
        public static DesktopProcess StartOnCurrentDesktop(string executable, string[] arguments)
        {
            return StartInternal(executable, arguments, false);
        }

        private static DesktopProcess StartInternal(string executable, string[] arguments, bool privateDesktop)
        {
            var result = new DesktopProcess();
            ProcessInformation child = new ProcessInformation();
            try
            {
                if (privateDesktop)
                {
                    result.DesktopName = "cua-rdp-" + Guid.NewGuid().ToString("N");
                    result.desktop = CreateDesktop(result.DesktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
                    if (result.desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktop failed.");
                }
                else result.DesktopName = CurrentDesktopName();
                result.job = CreateJobObject(IntPtr.Zero, null);
                if (result.job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
                var limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = 0x2000; // Children must die when the owner exits, including abnormal termination.
                if (!SetInformationJobObject(result.job, 9, ref limits, (uint)Marshal.SizeOf(limits)))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Setting the job's lifetime limit failed.");
                var startup = new StartupInfo();
                startup.cb = Marshal.SizeOf(startup);
                if (privateDesktop) startup.lpDesktop = "WinSta0\\" + result.DesktopName;
                var command = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
                // Suspended creation closes the race between launching the child and assigning its lifetime job.
                if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000004, IntPtr.Zero, System.IO.Path.GetDirectoryName(executable), ref startup, out child))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess on the worker desktop failed.");
                result.process = child.hProcess;
                result.ProcessId = child.dwProcessId;
                if (!AssignProcessToJobObject(result.job, child.hProcess))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed.");
                if (ResumeThread(child.hThread) == UInt32.MaxValue)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Resuming the RDP worker failed.");
                CloseHandle(child.hThread);
                child.hThread = IntPtr.Zero;
                return result;
            }
            catch
            {
                if (result.process != IntPtr.Zero) TerminateProcess(result.process, 1);
                if (child.hThread != IntPtr.Zero) CloseHandle(child.hThread);
                result.Dispose();
                throw;
            }
        }

        public bool HasExited
        {
            get { return process == IntPtr.Zero || WaitForSingleObject(process, 0) == 0; }
        }

        public int ExitCode
        {
            get
            {
                uint code;
                if (process == IntPtr.Zero || !GetExitCodeProcess(process, out code)) return -1;
                return unchecked((int)code);
            }
        }

        public void Dispose()
        {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) { WaitForSingleObject(process, 5000); CloseHandle(process); process = IntPtr.Zero; }
            if (desktop != IntPtr.Zero) { CloseDesktop(desktop); desktop = IntPtr.Zero; }
        }

        public static string Quote(string value)
        {
            if (value == null) throw new ArgumentNullException("value");
            var text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { text.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
                text.Append('\\', slashes).Append(c);
                slashes = 0;
            }
            return text.Append('\\', slashes * 2).Append('"').ToString();
        }

        private static string ObjectName(IntPtr handle)
        {
            int needed;
            var name = new StringBuilder(256);
            if (!GetUserObjectInformation(handle, 2, name, name.Capacity * 2, out needed))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading the desktop name failed.");
            return name.ToString();
        }

        public static string CurrentDesktopName()
        {
            return ObjectName(GetThreadDesktop(GetCurrentThreadId()));
        }

        public static string InputDesktopName()
        {
            IntPtr input = OpenInputDesktop(0, false, 1);
            if (input == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening the input desktop failed.");
            try { return ObjectName(input); }
            finally { CloseDesktop(input); }
        }
    }
}
