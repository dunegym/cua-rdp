using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CuaRdp.Native
{
    internal sealed class TypeLibraryImporter : ITypeLibImporterNotifySink
    {
        private static readonly Dictionary<string, Assembly> imports = new Dictionary<string, Assembly>();

        [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void LoadTypeLibEx(string file, int registrationKind, out ITypeLib library);

        public static Assembly Load()
        {
            ITypeLib library;
            LoadTypeLibEx(Path.Combine(Environment.SystemDirectory, "mstscax.dll"), 2, out library);
            try { return Import(library); }
            finally { Marshal.ReleaseComObject(library); }
        }

        private static Assembly Import(ITypeLib library)
        {
            IntPtr pointer;
            library.GetLibAttr(out pointer);
            string id;
            try { id = ((System.Runtime.InteropServices.ComTypes.TYPELIBATTR)Marshal.PtrToStructure(pointer, typeof(System.Runtime.InteropServices.ComTypes.TYPELIBATTR))).guid.ToString("N"); }
            finally { library.ReleaseTLibAttr(pointer); }
            Assembly existing;
            if (imports.TryGetValue(id, out existing)) return existing;
            // The system type library supplies exact vtables; handwritten non-scriptable COM layouts are unsafe.
            var assembly = new TypeLibConverter().ConvertTypeLibToAssembly(library,
                "CuaRdpInterop_" + id + ".dll", TypeLibImporterFlags.None,
                new TypeLibraryImporter(), null, null, "CuaRdpInterop", new Version(1, 0, 0, 0));
            imports.Add(id, assembly);
            return assembly;
        }

        public void ReportEvent(ImporterEventKind kind, int code, string message)
        {
            if (kind == ImporterEventKind.ERROR_REFTOINVALIDTYPELIB)
                throw new InvalidOperationException("The installed RDP type library could not be imported.");
        }

        public Assembly ResolveRef(object library) { return Import((ITypeLib)library); }
    }

    internal sealed class ComView
    {
        private readonly object instance;
        private readonly Type contract;
        public ComView(object instance, Assembly imported, string name)
        {
            this.instance = instance;
            contract = imported.GetType("CuaRdpInterop." + name, true);
        }
        public object Get(string name)
        {
            PropertyInfo property = contract.GetProperty(name);
            if (property == null) throw new MissingMemberException(contract.Name, name);
            return property.GetValue(instance, null);
        }
        public void Set(string name, object value)
        {
            PropertyInfo property = contract.GetProperty(name);
            if (property == null) throw new MissingMemberException(contract.Name, name);
            Type destination = property.PropertyType;
            if (value != null && !destination.IsInstanceOfType(value))
                value = destination.IsEnum ? Enum.ToObject(destination, value) : Convert.ChangeType(value, destination, CultureInfo.InvariantCulture);
            property.SetValue(instance, value, null);
        }
        public void SetExtended(string name, object value)
        {
            MethodInfo setter = contract.GetMethod("set_Property");
            ParameterInfo[] parameters = setter == null ? new ParameterInfo[0] : setter.GetParameters();
            if (parameters.Length != 2 || parameters[0].ParameterType != typeof(string) ||
                parameters[1].ParameterType != typeof(object).MakeByRefType() || setter.ReturnType != typeof(void))
                throw new InvalidOperationException("The installed RDP extended-property setter signature is not supported.");
            setter.Invoke(instance, new object[] { name, value });
        }
        public object GetExtended(string name)
        {
            MethodInfo getter = contract.GetMethod("get_Property", new Type[] { typeof(string) });
            if (getter == null || getter.ReturnType != typeof(object))
                throw new InvalidOperationException("The installed RDP extended-property getter signature is not supported.");
            return getter.Invoke(instance, new object[] { name });
        }
        public void Call(string name) { contract.GetMethod(name, Type.EmptyTypes).Invoke(instance, null); }
        public void SendKeys(int[] data)
        {
            ValidateSendKeys();
            // Tlbimp exposes the first elements as ref bool/ref int, not managed arrays. Obtain the
            // slot from that imported interface, then pass contiguous VARIANT_BOOL/LONG buffers.
            int slot = Marshal.GetComSlotForMethodInfo(contract.GetMethod("SendKeys"));
            IntPtr pointer = Marshal.GetComInterfaceForObject(instance, contract);
            try
            {
                IntPtr entry = Marshal.ReadIntPtr(Marshal.ReadIntPtr(pointer), slot * IntPtr.Size);
                var call = (NativeKeyBatch.SendKeysCall)Marshal.GetDelegateForFunctionPointer(entry, typeof(NativeKeyBatch.SendKeysCall));
                NativeKeyBatch.Invoke(pointer, call, data);
            }
            finally { Marshal.Release(pointer); }
        }
        public void ValidateSendKeys()
        {
            ParameterInfo[] parameters = contract.GetMethod("SendKeys").GetParameters();
            if (parameters.Length != 3 || parameters[0].ParameterType != typeof(int) ||
                parameters[1].ParameterType != typeof(bool).MakeByRefType() ||
                parameters[2].ParameterType != typeof(int).MakeByRefType())
                throw new InvalidOperationException("The installed RDP SendKeys signature is not supported.");
            if (Marshal.GetComSlotForMethodInfo(contract.GetMethod("SendKeys")) < 3)
                throw new InvalidOperationException("The imported SendKeys vtable slot is invalid.");
        }
    }

    internal static class NativeKeyBatch
    {
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        internal delegate int SendKeysCall(IntPtr self, int count, IntPtr keyUp, IntPtr keyData);

        internal static void Invoke(IntPtr self, SendKeysCall call, int[] data)
        {
            if (data == null || data.Length == 0 || data.Length > 20)
                throw new ArgumentException("SendKeys requires 1..20 strokes per atomic sequence.", "data");
            IntPtr keyUp = Marshal.AllocCoTaskMem(data.Length * 2);
            IntPtr keyData = IntPtr.Zero;
            try
            {
                keyData = Marshal.AllocCoTaskMem(data.Length * 4);
                for (int i = 0; i < data.Length; i++)
                {
                    // The wire payload is the scan code plus the 0x0100 extended flag; the sign
                    // bit is our private release marker and becomes the VARIANT_BOOL entry.
                    Marshal.WriteInt32(keyData, i * 4, data[i] & 0x1FF);
                    Marshal.WriteInt16(keyUp, i * 2, (short)(data[i] < 0 ? -1 : 0));
                }
                Marshal.ThrowExceptionForHR(call(self, data.Length, keyUp, keyData));
            }
            finally
            {
                Marshal.FreeCoTaskMem(keyUp);
                if (keyData != IntPtr.Zero) Marshal.FreeCoTaskMem(keyData);
            }
        }
    }

    [ComVisible(true)]
    [Guid("336D5562-EFA8-482E-8CB3-C5C0FC7A7DB6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface IRdpEvents
    {
        [DispId(1)] void OnConnecting();
        [DispId(2)] void OnConnected();
        [DispId(3)] void OnLoginComplete();
        [DispId(4)] void OnDisconnected(int reason);
        [DispId(10)] void OnFatalError(int code);
        [DispId(11)] void OnWarning(int code);
        [DispId(18)] void OnAuthenticationWarningDisplayed();
        [DispId(19)] void OnAuthenticationWarningDismissed();
        [DispId(22)] void OnLogonError(int code);
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class RdpEvents : StandardOleMarshalObject, IRdpEvents
    {
        private readonly RdpWindow owner;
        public RdpEvents(RdpWindow owner) { this.owner = owner; }
        public void OnConnecting() { }
        public void OnConnected() { }
        public void OnLoginComplete() { owner.LoginComplete(); }
        public void OnDisconnected(int reason)
        {
            if (reason == 2055)
            {
                // Observed on Windows 11 28120: the server drops prompt-free connections at NLA
                // negotiation before any credential exchange because every connection requires
                // an interactive password. Give the caller the actionable retry instead of a bare code.
                if (!owner.InteractiveAuthentication)
                    owner.Fail("RDP disconnected (reason 2055, 0x807). The server terminated this prompt-free connection before any credential exchange; this system likely requires an interactive Windows password on every connection. Retry desktop_start with authentication=interactive and complete the sign-in window.", "AUTHENTICATION_REQUIRED");
                else
                    owner.Fail("RDP disconnected (reason 2055, 0x807) before the interactive sign-in completed.");
                return;
            }
            owner.Fail("RDP disconnected (reason " + reason + ", 0x" + reason.ToString("X", CultureInfo.InvariantCulture) + ").");
        }
        public void OnFatalError(int code) { owner.Fail("RDP fatal error " + code + "."); }
        public void OnWarning(int code) { }
        public void OnAuthenticationWarningDisplayed() { owner.AuthenticationRequested(); }
        public void OnAuthenticationWarningDismissed() { }
        public void OnLogonError(int code)
        {
            if (code != -2) owner.Fail("RDP logon event " + code + "; interactive prompts are not supported.");
        }
    }

    internal sealed class RdpControl : AxHost
    {
        private ConnectionPointCookie cookie;
        private readonly RdpWindow owner;
        public RdpControl(RdpWindow owner) : base("8B918B82-7985-4C24-89DF-C33AD2BBFBCD") { this.owner = owner; }
        public object Instance { get { return GetOcx(); } }
        protected override void CreateSink()
        {
            base.CreateSink();
            cookie = new ConnectionPointCookie(GetOcx(), new RdpEvents(owner), typeof(IRdpEvents));
        }
        protected override void DetachSink()
        {
            if (cookie != null) { cookie.Disconnect(); cookie = null; }
            base.DetachSink();
        }
    }

    public static class BootstrapKeyboard
    {
        public static string ValidateGuestRoot(string root)
        {
            if (root == null) root = "C:\\ProgramData\\CuaRdp";
            if (root.Length > 200 || !System.Text.RegularExpressions.Regex.IsMatch(root, "\\A[A-Za-z]:\\\\[A-Za-z0-9._\\\\-]+\\z"))
                throw new ArgumentException("guestRoot must be an absolute ASCII drive path containing only letters, digits, dots, underscores, hyphens and backslashes; spaces are not typeable through the IME-safe keyboard bootstrap.");
            root = root.TrimEnd('\\');
            if (root.Length <= 3) throw new ArgumentException("guestRoot must name a directory below the drive root.");
            foreach (string part in root.Substring(3).Split('\\'))
            {
                if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(" ") || part.EndsWith("."))
                    throw new ArgumentException("guestRoot contains an empty, traversal or ambiguous path component.");
                if (System.Text.RegularExpressions.Regex.IsMatch(part, "\\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|\\z)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    throw new ArgumentException("guestRoot contains a reserved device name.");
            }
            return root;
        }

        public static string CommandFor(string id, string guestRoot)
        {
            if (id == null || !System.Text.RegularExpressions.Regex.IsMatch(id, "\\A[a-f0-9]{32}\\z"))
                throw new ArgumentException("The bootstrap id must contain exactly 32 lowercase hexadecimal characters.");
            // Typed while Caps Lock holds the session IME in direct-English mode: letters bypass the
            // pinyin composition window, quotes are dropped (space-free root) and Windows treats paths,
            // exe names and PowerShell switches case-insensitively; the guest normalizes the id.
            return "POWERSHELL.EXE -NOPROFILE -FILE " + ValidateGuestRoot(guestRoot).ToUpperInvariant() + "\\START-AGENT.PS1 -RUNID " + id.ToUpperInvariant();
        }

        // plKeyData carries raw set-1 scan codes, not the WM_KEYDOWN lParam layout the API
        // documentation describes: bits 0..7 are the scan code, bit 8 (0x0100) marks an extended
        // key, and the separate VARIANT_BOOL array carries the up state. The lParam layout sent
        // nothing to the child session on Windows 11 28120 while every call returned S_OK
        // (2026-10-13 bisect: production and the 10-12 delivering settings both failed); the raw
        // scan layout is field-proven on working child-session clients.
        public static int KeyData(int scanCode, bool up, bool extended)
        {
            if (scanCode < 1 || scanCode > 0xFF) throw new ArgumentOutOfRangeException("scanCode");
            return (scanCode & 0xFF) | (extended ? 0x0100 : 0) | (up ? unchecked((int)0x80000000) : 0);
        }

        private static readonly int[] LetterScans = { 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C };

        public static int[] Tap(int scanCode)
        {
            return new int[] { KeyData(scanCode, false, false), KeyData(scanCode, true, false) };
        }

        // Caps Lock provides direct English letters (no IME composition) in every IME state; only
        // the colon still needs Shift because the command itself is upper case.
        public static int[] EncodeCapsAscii(string text)
        {
            var encoded = new List<int>();
            const string letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            foreach (char character in text.ToUpperInvariant())
            {
                bool shift = false;
                int scan;
                int letter = letters.IndexOf(character);
                if (letter >= 0) scan = LetterScans[letter];
                else if (character >= '0' && character <= '9') scan = character == '0' ? 0x0B : character - '1' + 2;
                else if (character == ' ') scan = 0x39;
                else if (character == '-') scan = 0x0C;
                else if (character == '.') scan = 0x34;
                else if (character == '\\') scan = 0x2B;
                else if (character == '/') scan = 0x35;
                else if (character == ':') { scan = 0x27; shift = true; }
                else if (character == '_') { scan = 0x0C; shift = true; }
                else throw new ArgumentException("The fixed caps bootstrap command contains an unsupported character.");
                if (shift) encoded.Add(KeyData(0x2A, false, false));
                encoded.Add(KeyData(scan, false, false));
                encoded.Add(KeyData(scan, true, false));
                if (shift) encoded.Add(KeyData(0x2A, true, false));
            }
            return encoded.ToArray();
        }

        public static int[][] EncodeCapsBatches(string text)
        {
            var batches = new List<int[]>();
            var current = new List<int>();
            foreach (char character in text)
            {
                int[] strokes = EncodeCapsAscii(character.ToString());
                if (current.Count + strokes.Length > 20)
                {
                    batches.Add(current.ToArray());
                    current.Clear();
                }
                current.AddRange(strokes);
            }
            if (current.Count != 0) batches.Add(current.ToArray());
            return batches.ToArray();
        }

        public static int[] EncodeAscii(string text)
        {
            var encoded = new List<int>();
            const string letters = "abcdefghijklmnopqrstuvwxyz";
            int[] scanCodes = LetterScans;
            foreach (char character in text)
            {
                bool shift = character >= 'A' && character <= 'Z';
                int letter = letters.IndexOf(Char.ToLowerInvariant(character));
                int scan;
                if (letter >= 0) scan = scanCodes[letter];
                else if (character >= '1' && character <= '9') scan = character - '1' + 2;
                else if (character == '0') scan = 0x0B;
                else if (character == ' ') scan = 0x39;
                else if (character == '-') scan = 0x0C;
                else if (character == '_') { scan = 0x0C; shift = true; }
                else if (character == '.') scan = 0x34;
                else if (character == '\\') scan = 0x2B;
                else if (character == '/') scan = 0x35;
                else if (character == '>') { scan = 0x34; shift = true; }
                else if (character == ':') { scan = 0x27; shift = true; }
                else if (character == '"') { scan = 0x28; shift = true; }
                else throw new ArgumentException("The fixed bootstrap command contains an unsupported character.");
                if (shift) encoded.Add(KeyData(0x2A, false, false));
                encoded.Add(KeyData(scan, false, false));
                encoded.Add(KeyData(scan, true, false));
                if (shift) encoded.Add(KeyData(0x2A, true, false));
            }
            return encoded.ToArray();
        }

        public static int[][] EncodeBatches(string text)
        {
            var batches = new List<int[]>();
            var current = new List<int>();
            foreach (char character in text)
            {
                int[] strokes = EncodeAscii(character.ToString());
                if (current.Count + strokes.Length > 20)
                {
                    batches.Add(current.ToArray());
                    current.Clear();
                }
                current.AddRange(strokes);
            }
            if (current.Count != 0) batches.Add(current.ToArray());
            return batches.ToArray();
        }

        public static int[] Chord(int modifier, bool extended, int key)
        {
            return new int[] { KeyData(modifier, false, extended), KeyData(key, false, false),
                KeyData(key, true, false), KeyData(modifier, true, extended) };
        }
    }

    public static class BootstrapInputGate
    {
        public static bool CanSend(bool interactive, bool started, Dictionary<string, object> input)
        {
            // Interactive preparation is conservative; this is not a documented SendKeys focus prerequisite.
            if (!interactive) return true;
            object connected;
            if (input == null || !input.TryGetValue("clientConnected", out connected) || !Object.Equals(connected, 1) ||
                !Flag(input, "formVisible") || !Flag(input, "controlVisible") || !Flag(input, "inputCapturePresent") ||
                !Flag(input, "inputCaptureVisible") || !Flag(input, "inputCaptureEnabled"))
                throw new InvalidOperationException("The RDP input capture is not ready. No input was sent.");
            if (Flag(input, "threadFocusIsInputCapture") && Flag(input, "foregroundIsKeeper")) return true;
            if (interactive && !started) return false;
            throw new InvalidOperationException("RDP bootstrap lost input focus. Interactive preparation must remain focused until it hides. No input was sent and no earlier input was replayed.");
        }

        private static bool Flag(Dictionary<string, object> input, string name)
        {
            object value;
            return input.TryGetValue(name, out value) && Object.Equals(value, true);
        }
    }

    internal static class RdpInputObservation
    {
        private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] private static extern IntPtr GetFocus();
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool IsChild(IntPtr parent, IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsCallback callback, IntPtr parameter);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int count);

        internal static Dictionary<string, object> Capture(IntPtr form, IntPtr control, ComView client)
        {
            // Read only our own control's state. No window titles, text, keys, passwords or screenshots.
            var result = new Dictionary<string, object>();
            try { result["clientConnected"] = Convert.ToInt32(client.Get("Connected"), CultureInfo.InvariantCulture); }
            catch (Exception exception) { result["clientStateError"] = exception.GetBaseException().HResult; }
            IntPtr focus = GetFocus();
            IntPtr foreground = GetForegroundWindow();
            IntPtr capture = IntPtr.Zero;
            EnumChildWindows(control, delegate(IntPtr window, IntPtr parameter)
            {
                var name = new StringBuilder(64);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() == "IHWindowClass") { capture = window; return false; }
                return true;
            }, IntPtr.Zero);
            result["formVisible"] = IsWindowVisible(form);
            result["controlVisible"] = IsWindowVisible(control);
            result["threadFocusInControl"] = focus != IntPtr.Zero && (focus == control || IsChild(control, focus));
            result["threadFocusIsInputCapture"] = capture != IntPtr.Zero && focus == capture;
            result["foregroundIsKeeper"] = foreground != IntPtr.Zero && (foreground == form || IsChild(form, foreground));
            result["inputCapturePresent"] = capture != IntPtr.Zero;
            result["inputCaptureVisible"] = capture != IntPtr.Zero && IsWindowVisible(capture);
            result["inputCaptureEnabled"] = capture != IntPtr.Zero && IsWindowEnabled(capture);
            return result;
        }
    }

    public sealed class RdpWindow : Form
    {
        private readonly string statusPath;
        private readonly string stopPath;
        private readonly string bootstrapPath;
        private readonly string guestRoot;
        private readonly HashSet<string> attemptedBootstraps = new HashSet<string>();
        private string bootstrapId;
        private string bootstrapCommand;
        private DateTime nextBootstrapAction;
        private DateTime loginAt;
        private int bootstrapStage;
        private DateTime bootstrapVerifyAt;
        private ComView keyboard;
        private readonly string desktopName;
        private readonly int launcherPid;
        private readonly bool selfTest;
        private readonly bool interactiveAuthentication;
        internal bool InteractiveAuthentication { get { return interactiveAuthentication; } }
        private readonly bool windowVisible;
        private bool watchApplied;
        private bool parked;
        private bool parkPending;
        private Rectangle lastOnScreenBounds;
        private NotifyIcon trayIcon;
        private bool authenticationComplete;
        private bool backgroundReady;
        private bool inputFocusRequired;
        private string bootstrapPhase = "waiting-request";
        private Dictionary<string, object> inputState;
        private Dictionary<string, object> inputAtLogon;
        private Dictionary<string, object> inputBeforeBackground;
        private Dictionary<string, object> inputAfterBackground;
        private readonly ChildSessionExpectation expectedChild;
        private ChildSessionExpectation boundChild;
        private string boundUserSid;
        private string boundMachineGuid;
        private int rdpPort;
        private bool? connectToChildSession;
        private readonly DateTime started = DateTime.UtcNow;
        private readonly Timer timer = new Timer();
        private readonly RdpControl control;
        private readonly Assembly imported;
        private ComView client;
        private string state = "connecting";
        private string error;
        private string errorCode;
        private bool closing;
        private Process launcher;

        private RdpWindow(string statusPath, string stopPath, string bootstrapPath, string guestRoot, int launcherPid, bool selfTest, ChildSessionExpectation expectedChild, bool interactiveAuthentication, bool windowVisible)
        {
            this.statusPath = statusPath;
            this.stopPath = stopPath;
            this.bootstrapPath = bootstrapPath;
            this.guestRoot = BootstrapKeyboard.ValidateGuestRoot(guestRoot);
            this.launcherPid = launcherPid;
            this.selfTest = selfTest;
            this.expectedChild = expectedChild;
            this.interactiveAuthentication = interactiveAuthentication;
            // The watch window is a normal, user-manageable window kept after readiness (child
            // mode only, never in self-tests). Hidden mode keeps the off-screen keeper behavior.
            this.windowVisible = windowVisible && !selfTest && expectedChild != null;
            backgroundReady = !interactiveAuthentication || selfTest;
            if (interactiveAuthentication && expectedChild == null) throw new ArgumentException("Interactive authentication is only supported for Child Session.");
            if (expectedChild != null && this.guestRoot.Length > 160)
                throw new ArgumentException("Child Session guestRoot must be at most 160 characters.");
            desktopName = DesktopProcess.CurrentDesktopName();
            if (expectedChild != null)
            {
                // This build hosts Child Session on Default; private-desktop authentication stalled in local tests.
                // Background mode uses an off-screen no-activate window; input focus is observed, never changed.
                if (!desktopName.Equals("Default", StringComparison.Ordinal))
                    throw new InvalidOperationException("The Child Session RDP worker must run on the interactive Default desktop.");
                var screen = SystemInformation.VirtualScreen;
                Location = new Point(screen.Right + 64, screen.Top);
            }
            else
            {
                if (!desktopName.StartsWith("cua-rdp-", StringComparison.Ordinal))
                    throw new InvalidOperationException("The RDP worker is not on its private desktop.");
                Location = new Point(0, 0);
            }
            launcher = Process.GetProcessById(launcherPid);
            IntPtr launcherHandle = launcher.Handle;
            imported = TypeLibraryImporter.Load();
            Text = AllowInteractiveLogon ? "CuaRdp - Windows authentication (credentials are not saved)" : "CUA RDP keeper";
            // Keep ownership/taskbar settings fixed: changing ShowInTaskbar after login recreates the HWND.
            ShowInTaskbar = false;
            if (AllowInteractiveLogon) Location = new Point(Screen.PrimaryScreen.WorkingArea.Left + 32, Screen.PrimaryScreen.WorkingArea.Top + 32);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            StartPosition = FormStartPosition.Manual;
            MinimizeBox = false;
            MaximizeBox = false;
            control = new RdpControl(this);
            ((ISupportInitialize)control).BeginInit();
            control.Dock = DockStyle.Fill;
            Controls.Add(control);
            ((ISupportInitialize)control).EndInit();
            timer.Interval = 1000;
            timer.Tick += Tick;
            FormClosing += delegate(object sender, FormClosingEventArgs args)
            {
                // The user's close button parks the watch window off-screen (a minimized or
                // hidden window stops the RDP client from presenting, which kills in-session
                // capture); the taskbar entry and tray icon restore it. ParkOffScreen installs
                // the tray icon and shows the first-park balloon. External closes (taskbar
                // right-click "Close window") arrive as TaskManagerClosing and must park too,
                // not kill the connection. Only the keeper's own shutdown paths (stop marker,
                // owner exit, failure, disconnect menu) may close it. The park is deferred out
                // of the WM_CLOSE dispatch: parking synchronously there wedged the message
                // loop in the watch probe (same reentrancy class as the WM_SIZE park).
                if (!closing && watchApplied &&
                    (args.CloseReason == CloseReason.UserClosing || args.CloseReason == CloseReason.TaskManagerClosing))
                {
                    args.Cancel = true;
                    if (!parkPending)
                    {
                        parkPending = true;
                        BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                    }
                    return;
                }
                closing = true;
            };
            Resize += delegate
            {
                // A real minimize would stop remote presentation and break child-session
                // screenshots; park off-screen instead, keeping the taskbar entry. The park is
                // deferred out of the WM_SIZE dispatch the minimize itself produces: mutating
                // WindowState re-entrantly there can wedge the minimize bookkeeping.
                if (watchApplied && WindowState == FormWindowState.Minimized && !parkPending)
                {
                    parkPending = true;
                    BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                }
            };
            Activated += delegate
            {
                // Restoring from the taskbar or alt-tab while parked brings the window back.
                if (watchApplied && parked) RestoreWatchWindow();
            };
            FormClosed += delegate
            {
                if (trayIcon != null) { trayIcon.Visible = false; trayIcon.Dispose(); trayIcon = null; }
            };
        }

        internal bool IsChildSession { get { return expectedChild != null; } }

        private bool AllowInteractiveLogon { get { return interactiveAuthentication && !selfTest && !authenticationComplete; } }

        private bool VisiblePreparation { get { return interactiveAuthentication && !selfTest && !backgroundReady; } }

        private const uint WM_SYSCOMMAND_MESSAGE = 0x0112;
        private const long SC_MINIMIZE_COMMAND = 0xF020;
        private const long SC_CLOSE_COMMAND = 0xF060;

        protected override bool ShowWithoutActivation { get { return !VisiblePreparation; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams settings = base.CreateParams;
                if (!VisiblePreparation) settings.ExStyle |= 0x08000080;
                return settings;
            }
        }

        private void Configure(string address, int port, int width, int height, string userName, string domain, string password)
        {
            bool childMode = expectedChild != null;
            if (childMode && (!String.Equals(address, "localhost", StringComparison.OrdinalIgnoreCase) ||
                !String.IsNullOrEmpty(userName) || !String.IsNullOrEmpty(domain) || !String.IsNullOrEmpty(password)))
                throw new ArgumentException("Child Session connections must use localhost and no credentials.");
            rdpPort = port;
            ClientSize = AllowInteractiveLogon
                ? new Size(Math.Min(width, Screen.PrimaryScreen.WorkingArea.Width - 80), Math.Min(height, Screen.PrimaryScreen.WorkingArea.Height - 80))
                : new Size(width, height);
            Show();
            control.CreateControl();
            client = new ComView(control.Instance, imported, "IMsRdpClient9");
            var advanced = new ComView(client.Get("AdvancedSettings9"), imported, "IMsRdpClientAdvancedSettings8");
            var nonScriptable = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable5");
            keyboard = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable");
            keyboard.ValidateSendKeys();
            var basic = new ComView(client.Get("AdvancedSettings"), imported, "IMsTscAdvancedSettings");
            basic.Set("KeyBoardLayoutStr", "00000409");
            if (childMode)
            {
                // Kept alongside KeyboardHookMode; EnableWindowsKey alone is deprecated.
                advanced.Set("EnableWindowsKey", 1);
            }
            var secured = new ComView(client.Get("SecuredSettings3"), imported, "IMsRdpClientSecuredSettings2");
            // The fixed bootstrap starts with a remote Win+R. With only the deprecated
            // EnableWindowsKey the chord was dropped client-side: 2026-10-13 evidence showed the
            // child RunMRU untouched, no NoRun/NoWinKeys policy, no engine start, focus held.
            secured.Set("KeyboardHookMode", 1);
            if (Convert.ToInt32(secured.Get("KeyboardHookMode"), CultureInfo.InvariantCulture) != 1)
                throw new InvalidOperationException("The RDP KeyboardHookMode property was not retained.");
            client.Set("Server", childMode ? "localhost" : address);
            if (!childMode)
            {
                client.Set("UserName", userName);
                client.Set("Domain", domain);
            }
            var extended = new ComView(control.Instance, imported, "IMsRdpExtendedSettings");
            extended.SetExtended("ConnectToChildSession", childMode);
            object retainedMode = extended.GetExtended("ConnectToChildSession");
            if (!(retainedMode is bool) || (bool)retainedMode != childMode)
                throw new InvalidOperationException("The RDP ConnectToChildSession property was not retained.");
            connectToChildSession = (bool)retainedMode;
            client.Set("DesktopWidth", width);
            client.Set("DesktopHeight", height);
            client.Set("ColorDepth", 32);
            advanced.Set("RDPPort", port);
            // Background connections fail on server-authentication errors. Only explicit interactive
            // mode may show Windows' certificate/credential prompts; never auto-accept public keys.
            advanced.Set("AuthenticationLevel", interactiveAuthentication ? 2 : 1);
            advanced.Set("EnableCredSspSupport", true);
            advanced.Set("EnableAutoReconnect", false);
            advanced.Set("RedirectClipboard", false);
            advanced.Set("RedirectDrives", false);
            advanced.Set("RedirectPrinters", false);
            advanced.Set("RedirectPorts", false);
            advanced.Set("RedirectSmartCards", false);
            advanced.Set("RedirectDevices", false);
            advanced.Set("RedirectPOSDevices", false);
            advanced.Set("AudioCaptureRedirectionMode", false);
            advanced.Set("ConnectionBarShowMinimizeButton", false);
            advanced.Set("ConnectionBarShowRestoreButton", false);
            nonScriptable.Set("AllowCredentialSaving", false);
            nonScriptable.Set("AllowPromptingForCredentials", interactiveAuthentication);
            nonScriptable.Set("DisableConnectionBar", true);
            nonScriptable.Set("RedirectDynamicDevices", false);
            nonScriptable.Set("RedirectDynamicDrives", false);
            if (!interactiveAuthentication)
            {
                nonScriptable.Set("PromptForCredentials", false);
                nonScriptable.Set("PromptForCredsOnClient", false);
            }
            secured.Set("AudioRedirectionMode", 2);
            if (!childMode) advanced.Set("ClearTextPassword", password);
            WriteStatus();
            timer.Start();
            if (selfTest)
            {
                string testCommand = BootstrapKeyboard.CommandFor(new String('a', 32), guestRoot);
                if (BootstrapKeyboard.EncodeAscii(testCommand).Length < testCommand.Length * 2)
                    throw new InvalidOperationException("Bootstrap encoding self-test failed.");
                if (Convert.ToInt32(advanced.Get("AuthenticationLevel"), CultureInfo.InvariantCulture) != (interactiveAuthentication ? 2 : 1) ||
                    !Convert.ToBoolean(advanced.Get("EnableCredSspSupport"), CultureInfo.InvariantCulture))
                    throw new InvalidOperationException("The RDP security settings were not retained.");
                foreach (string name in new string[] { "AllowCredentialSaving", "RedirectDynamicDevices", "RedirectDynamicDrives" })
                    if (Convert.ToBoolean(nonScriptable.Get(name), CultureInfo.InvariantCulture))
                        throw new InvalidOperationException("The RDP setting must be disabled: " + name);
                if (Convert.ToBoolean(nonScriptable.Get("AllowPromptingForCredentials"), CultureInfo.InvariantCulture) != interactiveAuthentication)
                    throw new InvalidOperationException("Credential prompting did not match the explicit authentication mode.");
                if (interactiveAuthentication) EnterBackgroundMode();
                state = "self-test-passed";
                WriteStatus();
                return;
            }
            if (childMode)
            {
                ChildSessionState snapshot = ChildSessionNative.Capture();
                ChildSessionGuard.BeforeConnect(snapshot, expectedChild, rdpPort);
                boundUserSid = snapshot.userSid;
                boundMachineGuid = snapshot.machineGuid;
            }
            if (launcher.HasExited || File.Exists(stopPath)) throw new InvalidOperationException("The RDP owner stopped before connection.");
            client.Call("Connect");
        }

        public void AuthenticationRequested()
        {
            if (!AllowInteractiveLogon)
            {
                Fail("Windows requested interactive authentication. Background startup cannot answer this prompt. With the user's explicit consent, call desktop_start with authentication=interactive; Windows may require credentials on every connection.", "AUTHENTICATION_REQUIRED");
                return;
            }
            state = "authenticating";
            WriteStatus();
        }

        private void EnterBackgroundMode()
        {
            inputBeforeBackground = RdpInputObservation.Capture(Handle, control.Handle, client);
            IntPtr formHandle = Handle;
            object instance = control.Instance;
            Hide();
            backgroundReady = true;
            Text = "CUA RDP keeper";
            var screen = SystemInformation.VirtualScreen;
            Location = new Point(screen.Right + 64, screen.Top);
            UpdateStyles();
            Show();
            if (Handle != formHandle || !Object.ReferenceEquals(control.Instance, instance))
                throw new InvalidOperationException("The authentication transition recreated the RDP control; startup was stopped.");
            inputAfterBackground = RdpInputObservation.Capture(Handle, control.Handle, client);
        }

        private const int GWL_STYLE = -16;
        private const int GWL_EXSTYLE = -20;
        private const int WS_MINIMIZEBOX = 0x00020000;
        private const int WS_MAXIMIZEBOX = 0x00010000;
        private const int WS_THICKFRAME = 0x00040000;
        private const int WS_EX_NOACTIVATE_STYLE = 0x08000000;
        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const int WS_EX_APPWINDOW = 0x00040000;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOZORDER = 0x0004;
        private const uint SWP_FRAMECHANGED = 0x0020;
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool IsChild(IntPtr parent, IntPtr window);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
        private static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
        private static extern int SetWindowLong(IntPtr window, int index, int value);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        private delegate IntPtr WindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
        [DllImport("user32.dll", EntryPoint = "CallWindowProcW")]
        private static extern IntPtr CallWindowProc(IntPtr previous, IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

        // The RDP ActiveX control subclasses its host window and reacts to minimize/close
        // system commands before WinForms ever sees them (on Windows 11 28120 an external
        // SC_MINIMIZE tore down the connection even with a WndProc override installed).
        // This guard is installed once, at watch conversion, so it sits at the TOP of the
        // window-proc chain and swallows the commands into a deferred park instead.
        private WindowProc guardProc;
        private IntPtr previousGuardProc;

        private void InstallSystemCommandGuard()
        {
            if (previousGuardProc != IntPtr.Zero || guardProc != null) return;
            guardProc = GuardWindowProc;
            previousGuardProc = SetWindowLongPtr(Handle, -4 /* GWL_WNDPROC */, Marshal.GetFunctionPointerForDelegate(guardProc));
            if (previousGuardProc == IntPtr.Zero) throw new InvalidOperationException("The watch window command guard could not be installed.");
        }

        // The RDP control re-subclasses its host window at connect time, after the guard was
        // installed at watch conversion, which silently put the control's own procedure back
        // on top (measured on Windows 11 28120: posted system commands then bypassed the
        // guard entirely). The keeper tick re-arms the guard whenever it has been buried.
        private void EnsureGuardOnTop()
        {
            if (previousGuardProc == IntPtr.Zero || guardProc == null) return;
            IntPtr current = GetWindowLongPtrValue(Handle, -4);
            IntPtr mine = Marshal.GetFunctionPointerForDelegate(guardProc);
            if (current == mine) return;
            IntPtr buried = SetWindowLongPtr(Handle, -4 /* GWL_WNDPROC */, mine);
            if (buried != IntPtr.Zero && buried != mine) previousGuardProc = buried;
        }

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtrValue(IntPtr window, int index);

        private IntPtr GuardWindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
        {
            if (message == WM_SYSCOMMAND_MESSAGE)
            {
                long traceCommand = wParam.ToInt64() & 0xFFF0;
                if (watchApplied && !closing && (traceCommand == SC_MINIMIZE_COMMAND || traceCommand == SC_CLOSE_COMMAND))
                {
                    if (!parkPending)
                    {
                        parkPending = true;
                        BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                    }
                    return IntPtr.Zero;
                }
            }
            return CallWindowProc(previousGuardProc, window, message, wParam, lParam);
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct PropVariant
        {
            [FieldOffset(0)] public ushort Vt;
            [FieldOffset(8)] public IntPtr PointerValue;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid FormatId;
            public int PropertyId;
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }

        [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHGetPropertyStoreForWindow(IntPtr window, ref Guid interfaceId, out IPropertyStore store);

        // A dedicated per-window AppUserModelID keeps the watch window out of the console
        // host's taskbar group, so its entry is independently visible and restorable.
        private static void SetWindowAppUserModelId(IntPtr window, string appId)
        {
            var storeGuid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore store;
            SHGetPropertyStoreForWindow(window, ref storeGuid, out store);
            var key = new PropertyKey();
            key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            key.PropertyId = 5; // PKEY_AppUserModel_ID
            var value = new PropVariant();
            value.Vt = 31; // VT_LPWSTR
            value.PointerValue = Marshal.StringToCoTaskMemUni(appId);
            try
            {
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally { Marshal.FreeCoTaskMem(value.PointerValue); }
            Marshal.ReleaseComObject(store);
        }

        // Turns the authentication/preparation window into a retained watch window with normal
        // chrome (minimize, maximize, resize, taskbar). Styles are changed in place because
        // WinForms properties like FormBorderStyle/ShowInTaskbar would recreate the HWND and
        // destroy the RDP connection.
        private void BecomeWatchWindow()
        {
            if (watchApplied) return;
            inputBeforeBackground = RdpInputObservation.Capture(Handle, control.Handle, client);
            IntPtr formHandle = Handle;
            object instance = control.Instance;
            backgroundReady = true;
            watchApplied = true;
            try { new ComView(client.Get("AdvancedSettings9"), imported, "IMsRdpClientAdvancedSettings8").Set("SmartSizing", true); }
            catch (Exception) { }
            Text = "cua-rdp child session - minimize, maximize and tray are safe; desktop_stop ends the connection";
            if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
            parked = false;
            var area = Screen.PrimaryScreen.WorkingArea;
            ClientSize = new Size(Math.Min(ClientSize.Width, area.Width - 64), Math.Min(ClientSize.Height, area.Height - 64));
            Location = new Point(area.Left + 32, area.Top + 32);
            lastOnScreenBounds = new Rectangle(Location, Size);
            IntPtr handle = Handle;
            InstallSystemCommandGuard();
            SetWindowLong(handle, GWL_STYLE, GetWindowLong(handle, GWL_STYLE) | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_THICKFRAME);
            SetWindowLong(handle, GWL_EXSTYLE, (GetWindowLong(handle, GWL_EXSTYLE) & ~(WS_EX_NOACTIVATE_STYLE | WS_EX_TOOLWINDOW)) | WS_EX_APPWINDOW);
            SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
            SetWindowAppUserModelId(handle, "CuaRdp.ChildSession");
            // The Windows 11 taskbar does not reliably register a button for the in-place
            // ex-style flip above: the button tends to appear only after the next unrelated
            // shell event, leaving a just-parked watch window with no taskbar entry at all.
            // A same-HWND hide/show cycle registers it deterministically (measured 0/5
            // registered without, 5/5 with, on Windows 11 28120); the continuity check below
            // still guards against any HWND recreation.
            Hide();
            Show();
            // The tray icon exists from conversion time so a park never performs shell
            // interaction; it is the restore handle for both park paths.
            EnsureTray();
            if (Handle != formHandle || !Object.ReferenceEquals(control.Instance, instance))
                throw new InvalidOperationException("Showing the watch window recreated the RDP control; startup was stopped.");
            inputAfterBackground = RdpInputObservation.Capture(Handle, control.Handle, client);
        }

        private void EnsureTray()
        {
            if (trayIcon != null) return;
            trayIcon = new NotifyIcon();
            trayIcon.Icon = SystemIcons.Application;
            trayIcon.Text = "cua-rdp child session";
            trayIcon.Visible = true;
            trayIcon.DoubleClick += delegate { RestoreWatchWindow(); };
            var menu = new ContextMenuStrip();
            menu.Items.Add("Show window", null, delegate { RestoreWatchWindow(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Disconnect this connection", null, delegate { closing = true; BeginInvoke(new Action(Close)); });
            trayIcon.ContextMenuStrip = menu;
        }

        // Minimized or hidden windows stop the RDP client from presenting, which idles the child
        // session's graphics stack and breaks in-session GDI capture (BitBlt 0x80070006). Parking
        // keeps the window visible but outside the virtual screen (the state the hidden keeper
        // has always used), so rendering and screenshots continue in every parked state.
        private void ParkOffScreen()
        {
            var screen = SystemInformation.VirtualScreen;
            if (!parked)
            {
                var bounds = new Rectangle(Location, Size);
                if (bounds.Right > screen.Left + 16 && bounds.X < screen.Right - 16 && bounds.Bottom > screen.Top + 16 && bounds.Y < screen.Bottom - 16)
                    lastOnScreenBounds = bounds;
            }
            parked = true;
            // Presentation only continues while the window is visible; heal any hidden state
            // the RDP control may have produced before moving off-screen. This path is pure
            // window geometry: shell UI (the tray icon) is created once at watch conversion
            // instead, because first-time shell interaction at park time destabilized the RDP
            // control on the real keeper (Windows 11 28120).
            if (!Visible) Show();
            if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
            Location = new Point(screen.Right + 64, screen.Top);
        }

        private void RestoreWatchWindow()
        {
            parked = false;
            if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
            var area = Screen.PrimaryScreen.WorkingArea;
            var bounds = lastOnScreenBounds;
            if (bounds.Width <= 0 || bounds.Height <= 0 ||
                bounds.X < area.Left - 4096 || bounds.X > area.Right || bounds.Y < area.Top - 4096 || bounds.Y > area.Bottom)
                bounds = new Rectangle(area.Left + 32, area.Top + 32, ClientSize.Width, ClientSize.Height);
            Location = bounds.Location;
            Size = bounds.Size;
            Show();
            Activate();
        }

        public void LoginComplete()
        {
            if (closing || state == "failed" || state == "connected") return;
            try
            {
                if (expectedChild != null)
                {
                    ChildSessionState snapshot = ChildSessionNative.Capture();
                    if (snapshot.userSid != boundUserSid || snapshot.machineGuid != boundMachineGuid)
                        throw new InvalidOperationException("The Windows identity changed during Child Session login.");
                    boundChild = ChildSessionGuard.AfterLogin(snapshot, expectedChild, rdpPort);
                }
                authenticationComplete = true;
                inputAtLogon = RdpInputObservation.Capture(Handle, control.Handle, client);
                if (VisiblePreparation) Text = windowVisible
                    ? "CuaRdp - preparing child agent; a watch window will remain"
                    : "CuaRdp - preparing child agent; this window will hide before tasks";
                state = "connected";
                loginAt = DateTime.UtcNow;
                WriteStatus();
            }
            catch (Exception exception) { Fail("RDP login identity verification failed: " + exception.GetBaseException().Message); }
        }

        public void Fail(string message) { Fail(message, null); }

        internal void Fail(string message, string code)
        {
            if (closing || state == "failed") return;
            closing = true;
            state = "failed";
            error = message;
            errorCode = code;
            WriteStatus();
            if (IsHandleCreated) BeginInvoke(new Action(Close));
        }

        private void Tick(object sender, EventArgs args)
        {
            try
            {
                if (launcher.HasExited || File.Exists(stopPath)) { closing = true; Close(); return; }
                if ((state == "connecting" || state == "authenticating") && (DateTime.UtcNow - started).TotalSeconds > (interactiveAuthentication ? 300 : (expectedChild != null ? 30 : 120)))
                {
                    Fail(expectedChild != null
                        ? "Child Session login timed out. Windows may require credentials on every connection; background mode never opens a logon window. Check Child Session availability and RDP policy, or explicitly request interactive authentication."
                        : "RDP login timed out. Check the guest address, trusted certificate, NLA credentials and guest logon policy.");
                    return;
                }
                if (expectedChild != null && backgroundReady && !windowVisible)
                {
                    var screen = SystemInformation.VirtualScreen;
                    Location = new Point(screen.Right + 64, screen.Top);
                }
                else if (expectedChild != null && backgroundReady && windowVisible && parked)
                {
                    // Keep a parked watch window off-screen even after topology changes. If the
                    // window is on-screen AND the user is actively on it (foreground), treat the
                    // park as ended: a taskbar restore can land the window on-screen without the
                    // Activated handler running (the RDP input capture steals the activation),
                    // and dragging a just-restored window away again is exactly the
                    // "flies back to the right" bug.
                    var screen = SystemInformation.VirtualScreen;
                    if (Location.X < screen.Right)
                    {
                        IntPtr foreground = GetForegroundWindow();
                        if (foreground != IntPtr.Zero && (foreground == Handle || IsChild(Handle, foreground))) parked = false;
                        else Location = new Point(screen.Right + 64, screen.Top);
                    }
                }
                if (watchApplied) EnsureGuardOnTop();
                if (state == "connected" && !selfTest)
                {
                    if (expectedChild != null)
                        ChildSessionGuard.WhileConnected(ChildSessionNative.Capture(), boundChild, rdpPort, boundUserSid, boundMachineGuid);
                    BootstrapTick();
                }
                // Background-mode watch windows appear only after a successful connection;
                // interactive windows switch as soon as the agent bootstrap marker arrives.
                if (windowVisible && backgroundReady && !watchApplied && state == "connected" && !selfTest) BecomeWatchWindow();
                if (selfTest && (DateTime.UtcNow - started).TotalSeconds > 3) { Close(); return; }
                WriteStatus();
            }
            catch (Exception exception)
            {
                Fail(expectedChild == null ? "The RDP keeper health check failed." : "The Child Session health check failed: " + exception.GetBaseException().Message);
            }
        }

        private void BootstrapTick()
        {
            if (String.IsNullOrEmpty(bootstrapPath) || DateTime.UtcNow < loginAt.AddSeconds(5)) return;
            DateTime now = DateTime.UtcNow;
            if (now < nextBootstrapAction) return;
            if (bootstrapVerifyAt != default(DateTime))
            {
                // Only Child Session shares this filesystem. Hyper-V readiness is checked by its broker.
                string marker = Path.Combine(Path.Combine(Path.Combine(guestRoot, "runs"), bootstrapId), "bootstrap.started");
                if (File.Exists(marker))
                {
                    bootstrapPhase = "agent-started";
                    if (!backgroundReady)
                    {
                        if (windowVisible) BecomeWatchWindow();
                        else EnterBackgroundMode();
                    }
                    bootstrapId = null;
                    bootstrapVerifyAt = default(DateTime);
                }
                else if (now >= bootstrapVerifyAt)
                {
                    Fail("The Child Session bootstrap did not create its startup marker. Check the child shell, Run-dialog policy, keyboard layout and RDP input channel. No input was replayed and no host input was used.");
                }
                return;
            }
            if (bootstrapStage != 0)
            {
                if (bootstrapStage == 1)
                {
                    SendBootstrapKeys("select-command", BootstrapKeyboard.Chord(0x1D, false, 0x1E));
                    // Hold direct-English input while typing, then restore the caps state.
                    SendBootstrapKeys("caps-on", BootstrapKeyboard.Tap(0x3A));
                    foreach (int[] batch in BootstrapKeyboard.EncodeCapsBatches(bootstrapCommand)) SendBootstrapKeys("type-command", batch);
                    SendBootstrapKeys("caps-off", BootstrapKeyboard.Tap(0x3A));
                    bootstrapStage = 2;
                    nextBootstrapAction = now.AddSeconds(1.5);
                }
                else
                {
                    SendBootstrapKeys("submit-command", new int[] { BootstrapKeyboard.KeyData(0x1C, false, false), BootstrapKeyboard.KeyData(0x1C, true, false) });
                    bootstrapPhase = "waiting-marker";
                    bootstrapStage = 0;
                    bootstrapCommand = null;
                    if (expectedChild != null) bootstrapVerifyAt = now.AddSeconds(60);
                    else bootstrapId = null;
                }
                return;
            }
            if (!File.Exists(bootstrapPath)) return;
            var file = new FileInfo(bootstrapPath);
            if (file.Length > 4096) throw new InvalidOperationException("The bootstrap request is too large.");
            var request = new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(bootstrapPath));
            string id;
            string command;
            string launch;
            if (!request.TryGetValue("id", out id) || String.IsNullOrEmpty(id))
                throw new InvalidOperationException("The bootstrap request requires an id.");
            if (attemptedBootstraps.Contains(id)) return;
            request.TryGetValue("command", out command);
            request.TryGetValue("launch", out launch);
            if (launch == "task")
            {
                // The controller launches the staged agent through a temporary session-bound
                // scheduled task; no keys are sent, so a child-session IME cannot intercept the
                // bootstrap. Only watch for the startup marker and keep the background transition.
                if (!String.IsNullOrEmpty(command) || expectedChild == null)
                    throw new InvalidOperationException("Task bootstrap is only valid for the Child Session backend without a typed command.");
                attemptedBootstraps.Add(id);
                bootstrapId = id;
                bootstrapPhase = "waiting-marker";
                bootstrapVerifyAt = now.AddSeconds(60);
                return;
            }
            if (String.IsNullOrEmpty(command))
                throw new InvalidOperationException("The bootstrap request requires a command.");
            if (!String.Equals(command, BootstrapKeyboard.CommandFor(id, guestRoot), StringComparison.Ordinal))
                throw new InvalidOperationException("Only the fixed CuaRdp agent bootstrap command is accepted.");
            if (!CheckBootstrapInput("open-run", false)) return;
            attemptedBootstraps.Add(id);
            bootstrapId = id;
            bootstrapCommand = command;
            SendBootstrapKeys("open-run", BootstrapKeyboard.Chord(0x5B, true, 0x13));
            bootstrapStage = 1;
            nextBootstrapAction = now.AddSeconds(2.5);
        }

        private bool CheckBootstrapInput(string phase, bool started)
        {
            bootstrapPhase = phase;
            inputState = RdpInputObservation.Capture(Handle, control.Handle, client);
            inputFocusRequired = false;
            try
            {
                if (BootstrapInputGate.CanSend(interactiveAuthentication, started, inputState)) return true;
                inputFocusRequired = true;
                bootstrapPhase = "waiting-input-focus";
                Text = "CuaRdp - click this title bar; keep focused until this window hides";
                WriteStatus();
                return false;
            }
            catch (Exception exception)
            {
                inputFocusRequired = true;
                Fail("RDP input preflight failed at " + phase + ": " + exception.GetBaseException().Message, "RDP_INPUT_FOCUS_REQUIRED");
                throw;
            }
        }

        private void SendBootstrapKeys(string phase, int[] data)
        {
            CheckBootstrapInput(phase, true);
            WriteStatus();
            try { keyboard.SendKeys(data); }
            catch (Exception exception)
            {
                inputState = RdpInputObservation.Capture(Handle, control.Handle, client);
                Fail("RDP SendKeys failed at " + phase + " (HRESULT 0x" + exception.GetBaseException().HResult.ToString("X8", CultureInfo.InvariantCulture) + "). No input was replayed.", "RDP_INPUT_FAILED");
                throw;
            }
        }

        private void WriteStatus()
        {
            var detail = new Dictionary<string, object>();
            detail["backgroundReady"] = backgroundReady;
            detail["watchWindow"] = watchApplied;
            detail["bootstrapPhase"] = bootstrapPhase;
            detail["inputFocusRequired"] = inputFocusRequired;
            if (inputState != null) detail["input"] = inputState;
            if (inputAtLogon != null) detail["inputAtLogon"] = inputAtLogon;
            if (inputBeforeBackground != null) detail["inputBeforeBackground"] = inputBeforeBackground;
            if (inputAfterBackground != null) detail["inputAfterBackground"] = inputAfterBackground;
            WriteState(statusPath, state, desktopName, error, bootstrapId, boundChild, connectToChildSession, errorCode, detail);
        }

        public static void WriteState(string path, string state, string desktop, string error, string bootstrapId)
        {
            WriteState(path, state, desktop, error, bootstrapId, null, null, null, null);
        }

        private static void WriteState(string path, string state, string desktop, string error, string bootstrapId,
            ChildSessionExpectation identity, bool? childMode, string errorCode, Dictionary<string, object> detail)
        {
            var message = new Dictionary<string, object>();
            message["state"] = state;
            message["pid"] = Process.GetCurrentProcess().Id;
            message["desktop"] = desktop;
            message["updatedAt"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            if (error != null) message["error"] = error;
            if (errorCode != null) message["errorCode"] = errorCode;
            if (bootstrapId != null) message["bootstrapId"] = bootstrapId;
            if (childMode.HasValue) message["connectToChildSession"] = childMode.Value;
            if (identity != null)
            {
                message["parentSessionId"] = identity.ParentSessionId;
                message["parentLogonTime"] = identity.ParentLogonTime;
                message["childSessionId"] = identity.ChildSessionId;
                message["childLogonTime"] = identity.ChildLogonTime;
            }
            if (detail != null) foreach (var entry in detail) message[entry.Key] = entry.Value;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(message), new UTF8Encoding(false));
            try
            {
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        public static void Run(string statusPath, string stopPath, string bootstrapPath, string guestRoot, int launcherPid, string address, int port,
            int width, int height, string userName, string domain, string password, bool selfTest)
        {
            Run(statusPath, stopPath, bootstrapPath, guestRoot, launcherPid, address, port, width, height, userName, domain, password, selfTest, null, false, false);
        }

        public static void Run(string statusPath, string stopPath, string bootstrapPath, string guestRoot, int launcherPid, string address, int port,
            int width, int height, string userName, string domain, string password, bool selfTest, ChildSessionExpectation expectedChild)
        {
            Run(statusPath, stopPath, bootstrapPath, guestRoot, launcherPid, address, port, width, height, userName, domain, password, selfTest, expectedChild, false, false);
        }

        public static void Run(string statusPath, string stopPath, string bootstrapPath, string guestRoot, int launcherPid, string address, int port,
            int width, int height, string userName, string domain, string password, bool selfTest, ChildSessionExpectation expectedChild, bool interactiveAuthentication, bool windowVisible)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var window = new RdpWindow(statusPath, stopPath, bootstrapPath, guestRoot, launcherPid, selfTest, expectedChild, interactiveAuthentication, windowVisible))
            {
                try
                {
                    window.Configure(address, port, width, height, userName, domain, password);
                    password = null;
                    Application.Run(window);
                }
                finally
                {
                    window.closing = true;
                    window.timer.Stop();
                    window.timer.Dispose();
                    if (window.client != null)
                    {
                        try { window.client.Call("Disconnect"); } catch (Exception) { }
                    }
                    if (window.state != "failed" && !selfTest) window.state = "stopped";
                    window.WriteStatus();
                    window.launcher.Dispose();
                }
            }
        }
    }
}
