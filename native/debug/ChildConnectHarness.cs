using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows.Forms;
using System.Drawing;

namespace CuaRdp.Diag
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
            var assembly = new TypeLibConverter().ConvertTypeLibToAssembly(library,
                "CuaRdpDiagInterop_" + id + ".dll", TypeLibImporterFlags.None,
                new TypeLibraryImporter(), null, null, "CuaRdpDiagInterop", new Version(1, 0, 0, 0));
            imports.Add(id, assembly);
            return assembly;
        }

        public void ReportEvent(ImporterEventKind kind, int code, string message) { }
        public Assembly ResolveRef(object library) { return Import((ITypeLib)library); }
    }

    internal sealed class ComView
    {
        private readonly object instance;
        private readonly Type contract;
        public ComView(object instance, Assembly imported, string name)
        {
            this.instance = instance;
            contract = imported.GetType("CuaRdpDiagInterop." + name, true);
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
            new CuaRdp.Native.ComView(instance, CuaRdp.Native.TypeLibraryImporter.Load(), "IMsRdpClientNonScriptable").SendKeys(data);
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
        [DispId(12)] void OnRemoteDesktopSizeChange(int width, int height);
        [DispId(17)] void OnAutoReconnecting(int reason, int attemptCount, out int continueStatus);
        [DispId(16)] void OnReceivedTSPublicKey(string publicKey, out bool continueLogon);
        [DispId(18)] void OnAuthenticationWarningDisplayed();
        [DispId(19)] void OnAuthenticationWarningDismissed();
        [DispId(22)] void OnLogonError(int code);
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class RdpEvents : StandardOleMarshalObject, IRdpEvents
    {
        private readonly ChildConnectForm owner;
        public RdpEvents(ChildConnectForm owner) { this.owner = owner; }
        public void OnConnecting() { owner.Log("event OnConnecting"); }
        public void OnConnected() { owner.Log("event OnConnected"); }
        public void OnReceivedTSPublicKey(string publicKey, out bool continueLogon) { owner.Log("event OnReceivedTSPublicKey len=" + (publicKey == null ? -1 : publicKey.Length)); continueLogon = true; }
        public void OnLoginComplete() { owner.Log("event OnLoginComplete"); owner.AfterLogin(); }
        public void OnDisconnected(int reason) { owner.Log("event OnDisconnected reason=" + reason + " hex=0x" + reason.ToString("X", CultureInfo.InvariantCulture)); owner.AfterDisconnect(); }
        public void OnFatalError(int code) { owner.Log("event OnFatalError code=" + code + " hex=0x" + code.ToString("X", CultureInfo.InvariantCulture)); owner.AfterDisconnect(); }
        public void OnWarning(int code) { owner.Log("event OnWarning code=" + code); }
        public void OnRemoteDesktopSizeChange(int width, int height) { owner.Log("event OnRemoteDesktopSizeChange " + width + "x" + height); }
        public void OnAutoReconnecting(int reason, int attemptCount, out int continueStatus) { owner.Log("event OnAutoReconnecting reason=" + reason + " attempt=" + attemptCount); continueStatus = 0; }
        public void OnAuthenticationWarningDisplayed() { owner.Log("event OnAuthenticationWarningDisplayed"); owner.DumpDialogs(); owner.DumpAutomation(); owner.RequestEnterAnswer(); }
        public void OnAuthenticationWarningDismissed() { owner.Log("event OnAuthenticationWarningDismissed"); }
        public void OnLogonError(int code) { owner.Log("event OnLogonError code=" + code + " hex=0x" + code.ToString("X", CultureInfo.InvariantCulture)); }
    }

    internal sealed class DiagControl : AxHost
    {
        private ConnectionPointCookie cookie;
        private readonly RdpEvents events;
        private readonly string clsid;
        public DiagControl(RdpEvents events, string clsid) : base(clsid) { this.events = events; this.clsid = clsid; }
        public object Instance { get { return GetOcx(); } }
        public string Clsid { get { return clsid; } }
        protected override void CreateSink()
        {
            base.CreateSink();
            cookie = new ConnectionPointCookie(GetOcx(), events, typeof(IRdpEvents));
        }
        protected override void DetachSink()
        {
            if (cookie != null) { cookie.Disconnect(); cookie = null; }
            base.DetachSink();
        }
    }

    public sealed class ChildConnectForm : Form
    {
        private readonly CuaRdp.Native.ChildSessionExpectation expectedChild;
        private readonly string logPath;
        private readonly string preset;
        private readonly int port;
        private readonly int width;
        private readonly int height;
        private readonly int timeoutSeconds;
        private readonly Assembly imported;
        private readonly object logGate = new object();
        private DiagControl control;
        private ComView client;
        private ComView client7;
        private ComView keyboard;
        private readonly Timer timeout = new Timer();
        private readonly Timer followUp = new Timer();
        private readonly Timer answerTimer = new Timer();
        private int answerAttempts;
        private int result = 3;
        private bool closing;

        private readonly string securityFlavor;
        private readonly string clientSettings;
        private ChildConnectForm(string logPath, string preset, int port, int width, int height, int timeoutSeconds, string securityFlavor,
            string clientSettings, CuaRdp.Native.ChildSessionExpectation ownedExpectation)
        {
            var snapshot = CuaRdp.Native.ChildSessionNative.Capture();
            if (ownedExpectation == null)
            {
                if (snapshot.childSessionId.HasValue) throw new InvalidOperationException("Debug harness refuses an existing child.");
                expectedChild = new CuaRdp.Native.ChildSessionExpectation(snapshot.parentSessionId, snapshot.parentLogonTime, null, null);
            }
            else expectedChild = ownedExpectation;
            CuaRdp.Native.ChildSessionGuard.BeforeConnect(snapshot, expectedChild, port);
            this.logPath = logPath;
            this.preset = preset;
            this.port = port;
            this.width = width;
            this.height = height;
            this.timeoutSeconds = timeoutSeconds;
            this.securityFlavor = securityFlavor;
            this.clientSettings = clientSettings;
            imported = TypeLibraryImporter.Load();
            Text = "CuaRdp Child Session diagnostic";
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            StartPosition = FormStartPosition.Manual;
            if (securityFlavor == "offscreen")
            {
                // Beyond the right edge of the virtual screen: on the user's desktop but not on any monitor.
                var bounds = System.Windows.Forms.Screen.GetBounds(System.Drawing.Point.Empty);
                Location = new Point(bounds.Right + 64, bounds.Top);
            }
            else
            {
                Location = new Point(20, 20);
            }
            if (securityFlavor == "ghost") Opacity = 0.01;
            Size = new Size(420, 320);
            if (securityFlavor == "keytest") ClientSize = new Size(804, 604);
            if (securityFlavor == "interactive")
            {
                Text = "CuaRdp Child Session interactive authentication - enter your Windows password below to sign in; you may close this window afterwards";
                Location = new Point(200, 100);
                ClientSize = new Size(1004, 644);
                ShowInTaskbar = true;
                TopMost = true;
            }
            MinimizeBox = false;
            MaximizeBox = false;
            timeout.Interval = timeoutSeconds * 1000;
            timeout.Tick += delegate
            {
                Log("timeout reached; exiting");
                try { client.Call("Disconnect"); } catch (Exception) { }
                Environment.Exit(3);
            };
            followUp.Interval = 1500;
            followUp.Tick += FollowUp;
            answerTimer.Interval = 2500;
            answerTimer.Tick += delegate
            {
                if (++answerAttempts > 8) { answerTimer.Stop(); return; }
                Log("answer attempt " + answerAttempts);
                SendEnterToControl();
            };
            captureTimer.Interval = 3500;
            captureTimer.Tick += CaptureSurface;
            keyTimer.Interval = 3000;
            keyTimer.Tick += delegate { KeyTestTick(); };
            FormClosing += delegate { closing = true; };
        }

        protected override bool ShowWithoutActivation { get { return securityFlavor != "interactive"; } }

        public static int Run(string logPath, string preset, int port, int width, int height, int timeoutSeconds, string securityFlavor)
        {
            return Run(logPath, preset, port, width, height, timeoutSeconds, securityFlavor, "minimal", null);
        }

        public static int Run(string logPath, string preset, int port, int width, int height, int timeoutSeconds, string securityFlavor,
            string clientSettings, CuaRdp.Native.ChildSessionExpectation ownedExpectation)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var window = new ChildConnectForm(logPath, preset, port, width, height, timeoutSeconds, securityFlavor, clientSettings, ownedExpectation))
            {
                try { Application.Run(window); }
                finally
                {
                    window.closing = true;
                    window.timeout.Stop(); window.timeout.Dispose();
                    window.followUp.Stop(); window.followUp.Dispose();
                    try { if (window.client != null) window.client.Call("Disconnect"); } catch (Exception) { }
                }
            }
            return ReadResult(logPath);
        }

        private static int ReadResult(string logPath)
        {
            foreach (string line in File.ReadAllLines(logPath))
                if (line.Contains("\"result\""))
                {
                    var match = System.Text.RegularExpressions.Regex.Match(line, "\"result\":\\s*(\\d+)");
                    if (match.Success) return int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
                }
            return 3;
        }

        public void Log(string message)
        {
            string line = string.Format(CultureInfo.InvariantCulture, "{{\"t\":\"{0}\",\"msg\":{1}}}",
                DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                JsonEscape(message));
            lock (logGate) { File.AppendAllText(logPath, line + "\n"); }
            try { Console.WriteLine(message); } catch (IOException) { }
        }

        private static string JsonEscape(string value)
        {
            var sb = new System.Text.StringBuilder("\"");
            foreach (char c in value) sb.Append(c == '"' || c == '\\' ? '\\' + c.ToString() : c < ' ' ? " " : c.ToString());
            return sb.Append('"').ToString();
        }

        protected override void OnShown(EventArgs args)
        {
            base.OnShown(args);
            try
            {
                if (securityFlavor == "activate")
                {
                    Activate();
                    Log("activated form for authentication UI");
                }
                Configure();
                timeout.Start();
                Log("calling Connect");
                CuaRdp.Native.ChildSessionGuard.BeforeConnect(CuaRdp.Native.ChildSessionNative.Capture(), expectedChild, port);
                client.Call("Connect");
            }
            catch (Exception exception) { Fail(exception); }
        }

        private void Configure()
        {
            string clsid = preset == "bettergi" ? "A0C63C30-F08D-4AB4-907C-34905D770C7D" : "8B918B82-7985-4C24-89DF-C33AD2BBFBCD";
            control = new DiagControl(new RdpEvents(this), clsid);
            ((System.ComponentModel.ISupportInitialize)control).BeginInit();
            control.Dock = DockStyle.Fill;
            Controls.Add(control);
            ((System.ComponentModel.ISupportInitialize)control).EndInit();
            control.CreateControl();
            Log("hosted clsid " + clsid + " preset " + preset + " port " + port + " desktop " +
                CuaRdp.Native.DesktopProcess.CurrentDesktopName() + " inputDesktop " + CuaRdp.Native.DesktopProcess.InputDesktopName());
            client = new ComView(control.Instance, imported, "IMsRdpClient10");
            client7 = new ComView(control.Instance, imported, "IMsRdpClient7");
            keyboard = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable");
            client.Set("Server", "localhost");
            client.Set("DesktopWidth", width);
            client.Set("DesktopHeight", height);
            client.Set("ColorDepth", 32);
            ComView advanced = AdvancedView();
            advanced.Set("RDPPort", port);
            advanced.Set("EnableCredSspSupport", true);
            if (securityFlavor == "nla-off") advanced.Set("EnableCredSspSupport", false);
            if (securityFlavor == "public-mode") advanced.Set("PublicMode", true);
            if (securityFlavor == "dummy-creds")
            {
                client.Set("UserName", "cuarpd-probe");
                client.Set("Domain", "");
                advanced.Set("ClearTextPassword", "cuarpd-probe");
            }
            if (securityFlavor == "machine-name")
            {
                client.Set("Server", Environment.MachineName);
            }
            if (securityFlavor == "trusted-zone" || securityFlavor == "mark-secure")
            {
                ComView nonScriptableExtra = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable4");
                if (securityFlavor == "trusted-zone") nonScriptableExtra.Set("TrustedZoneSite", true);
                if (securityFlavor == "mark-secure") nonScriptableExtra.Set("MarkRdpSettingsSecure", true);
            }
            ComView secured = new ComView(client.Get("SecuredSettings2"), imported, "IMsRdpClientSecuredSettings2");
            bool production = clientSettings.StartsWith("production", StringComparison.Ordinal);
            if (!production)
            {
                secured.Set("AudioRedirectionMode", 2);
                secured.Set("KeyboardHookMode", 1);
            }
            if (production)
            {
                // Mirrors the production child-mode client exactly, minus the parts under test.
                if (clientSettings != "production-nolayout")
                {
                    ComView basic = new ComView(client.Get("AdvancedSettings"), imported, "IMsTscAdvancedSettings");
                    basic.Set("KeyBoardLayoutStr", "00000409");
                }
                if (clientSettings != "production-nowek") advanced.Set("EnableWindowsKey", 1);
                secured.Set("KeyboardHookMode", 1);
                // Interactive production configuration: NLA completes with a user-entered password.
                // Level 1 without prompts disconnects with 2055 before any logon.
                advanced.Set("AuthenticationLevel", 2);
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
                ComView nonScriptable5 = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable5");
                nonScriptable5.Set("AllowCredentialSaving", false);
                nonScriptable5.Set("AllowPromptingForCredentials", true);
                nonScriptable5.Set("DisableConnectionBar", true);
            }
            if (preset == "cua-rdp")
            {
                advanced.Set("AuthenticationLevel", 0);
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
                ComView basic = new ComView(client.Get("AdvancedSettings"), imported, "IMsTscAdvancedSettings");
                basic.Set("KeyBoardLayoutStr", "00000409");
                ComView nonScriptable = new ComView(control.Instance, imported, "IMsRdpClientNonScriptable5");
                // Unattended private desktop: the CredSSP/redirection consent dialogs must never appear.
                nonScriptable.Set("ShowRedirectionWarningDialog", false);
                nonScriptable.Set("WarnAboutSendingCredentials", false);
                nonScriptable.Set("WarnAboutClipboardRedirection", false);
            }
            ComView extended = new ComView(control.Instance, imported, "IMsRdpExtendedSettings");
            extended.SetExtended("ConnectToChildSession", true);
            object retained = extended.GetExtended("ConnectToChildSession");
            Log("ConnectToChildSession readback " + retained);
            if (!(retained is bool) || !(bool)retained) throw new InvalidOperationException("ConnectToChildSession was not retained.");
        }

        private ComView AdvancedView()
        {
            foreach (string name in new[] { "AdvancedSettings9", "AdvancedSettings8", "AdvancedSettings7", "AdvancedSettings" })
            {
                try { return new ComView(client.Get(name), imported, "IMsRdpClientAdvancedSettings8"); }
                catch (MissingMemberException) { }
            }
            throw new InvalidOperationException("No advanced settings view was available.");
        }

        internal void AfterLogin()
        {
            try { CuaRdp.Native.ChildSessionGuard.AfterLogin(CuaRdp.Native.ChildSessionNative.Capture(), expectedChild, port); }
            catch (Exception exception) { Fail(exception); return; }
            result = securityFlavor == "keytest" ? 2 : 0;
            if (securityFlavor == "keytest" || securityFlavor == "peek")
            {
                keyTimer.Start();
            }
            else if (securityFlavor == "interactive")
            {
                Log("interactive: log on in this window if Windows asks for credentials; the session stays logged in after the window closes");
            }
            else followUp.Start();
        }

        internal void AfterDisconnect()
        {
            if (result != 0) result = 2;
            followUp.Start();
        }

        private void FollowUp(object sender, EventArgs args)
        {
            followUp.Stop();
            try { Log("ExtendedDisconnectReason " + client7.Get("ExtendedDisconnectReason")); }
            catch (Exception exception) { Log("ExtendedDisconnectReason unavailable: " + exception.GetBaseException().Message); }
            try
            {
                var snapshot = CuaRdp.Native.ChildSessionNative.Capture();
                Log("wts childSessionId=" + snapshot.childSessionId + " childState=" + snapshot.childState +
                    " childProtocol=" + snapshot.childProtocol + " parentSessionId=" + snapshot.parentSessionId);
            }
            catch (Exception exception) { Log("wts snapshot unavailable: " + exception.GetBaseException().Message); }
            if (result == 0 && !closing)
            {
                try { Log("Connected property " + client.Get("Connected")); } catch (Exception) { }
            }
            Close();
        }

        private delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr handle, System.Text.StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr handle, System.Text.StringBuilder text, int count);
        [DllImport("user32.dll")]
        private static extern IntPtr GetFocus();

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr handle, out RECT rectangle);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }

        internal void DumpDialogs()
        {
            try
            {
                uint current = (uint)Process.GetCurrentProcess().Id;
                EnumWindows(delegate(IntPtr handle, IntPtr parameter)
                {
                    uint owner;
                    GetWindowThreadProcessId(handle, out owner);
                    if (owner != current || !IsWindowVisible(handle)) return true;
                    var title = new System.Text.StringBuilder(512);
                    var className = new System.Text.StringBuilder(256);
                    GetWindowText(handle, title, title.Capacity);
                    GetClassName(handle, className, className.Capacity);
                    Log("window class=" + className + " title=" + title);
                    return true;
                }, IntPtr.Zero);
                if (IsHandleCreated)
                {
                    EnumChildWindows(Handle, delegate(IntPtr child, IntPtr state)
                    {
                        var childTitle = new System.Text.StringBuilder(512);
                        var childClass = new System.Text.StringBuilder(256);
                        GetClassName(child, childClass, childClass.Capacity);
                        GetWindowText(child, childTitle, childTitle.Capacity);
                        RECT rect;
                        GetWindowRect(child, out rect);
                        Log("child hwnd=" + child + " class=" + childClass + " title=" + childTitle +
                            " visible=" + IsWindowVisible(child) +
                            " rect=" + rect.Left + "," + rect.Top + "," + rect.Right + "," + rect.Bottom);
                        return true;
                    }, IntPtr.Zero);
                }
            }
            catch (Exception exception) { Log("dump failed: " + exception.GetBaseException().Message); }
        }

        internal void DumpAutomation()
        {
            try
            {
                var root = System.Windows.Automation.AutomationElement.FromHandle(Handle);
                var elements = root.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition);
                int count = 0;
                foreach (System.Windows.Automation.AutomationElement element in elements)
                {
                    if (count++ > 80) { Log("uia ...truncated"); break; }
                    string name = element.Current.Name ?? "";
                    if (name.Length > 0) Log("uia " + element.Current.ControlType.ProgrammaticName + " name=" + name);
                }
            }
            catch (Exception exception) { Log("uia dump failed: " + exception.GetBaseException().Message); }
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr window, int message, IntPtr wparam, IntPtr lparam);
        [DllImport("user32.dll")]
        private static extern IntPtr SetFocus(IntPtr window);

        private void SendEnterToControl()
        {
            try
            {
                var targets = new List<IntPtr>();
                EnumChildWindows(Handle, delegate(IntPtr child, IntPtr state)
                {
                    var childClass = new System.Text.StringBuilder(256);
                    GetClassName(child, childClass, childClass.Capacity);
                    string name = childClass.ToString();
                    if (name == "IHWindowClass" || name == "UIContainerClass" || name.StartsWith("ATL:", StringComparison.Ordinal)) targets.Add(child);
                    return true;
                }, IntPtr.Zero);
                foreach (IntPtr target in targets)
                {
                    Log("sending Enter to hwnd=" + target);
                    PostMessage(target, 0x0100, (IntPtr)0x0D, IntPtr.Zero);
                    PostMessage(target, 0x0102, (IntPtr)0x0D, IntPtr.Zero);
                    PostMessage(target, 0x0101, (IntPtr)0x0D, IntPtr.Zero);
                }
            }
            catch (Exception exception) { Log("enter failed: " + exception.GetBaseException().Message); }
        }

        private void KeyTestTick()
        {
            keyTimer.Stop();
            if (securityFlavor == "peek")
            {
                CaptureSurface(null, null);
                Log("peek: captured the child session surface without sending any keys");
                Close();
                return;
            }
            string marker = logPath + ".KP";
            try
            {
                if (keyStage == 0)
                {
                    Log("keytest [" + clientSettings + "]: waiting 5s after login");
                    keyStage = 1;
                    keyTimer.Interval = 5000;
                    keyTimer.Start();
                    return;
                }
                if (keyStage == 1)
                {
                    // BetterGI's working client sets keyboard focus to the RDP input capture
                    // window before every SendKeys; replicate that here and log the result.
                    Log("keytest: input-capture focus before Win+R = " + FocusInputCapture());
                    keyboard.SendKeys(CuaRdp.Native.BootstrapKeyboard.Chord(0x5B, true, 0x13));
                    Log("keytest: sent Win+R");
                    keyStage = 2;
                    keyTimer.Interval = 2500;
                    keyTimer.Start();
                    return;
                }
                if (keyStage == 2)
                {
                    if (marker.IndexOf(' ') >= 0) throw new InvalidOperationException("The keytest marker path must be space-free.");
                    string command = ("CMD.EXE /C COPY NUL " + marker).ToUpperInvariant();
                    keyboard.SendKeys(CuaRdp.Native.BootstrapKeyboard.Chord(0x1D, false, 0x1E));
                    keyboard.SendKeys(CuaRdp.Native.BootstrapKeyboard.Tap(0x3A));
                    foreach (int[] batch in CuaRdp.Native.BootstrapKeyboard.EncodeCapsBatches(command)) keyboard.SendKeys(batch);
                    keyboard.SendKeys(CuaRdp.Native.BootstrapKeyboard.Tap(0x3A));
                    Log("keytest: typed the caps marker command");
                    keyStage = 3;
                    keyTimer.Interval = 1500;
                    keyTimer.Start();
                    return;
                }
                if (keyStage == 3)
                {
                    SendOne(0x1C, false, false);
                    SendOne(0x1C, true, false);
                    Log("keytest: submitted Enter");
                    keyStage = 4;
                    keyTimer.Interval = 5000;
                    keyTimer.Start();
                    return;
                }
                bool exists = File.Exists(marker);
                Log("keytest: marker exists = " + exists);
                result = exists ? 0 : 2;
            }
            catch (Exception exception) { Log("keytest failed: " + exception.GetBaseException().Message); }
            Close();
        }

        private void SendOne(int scanCode, bool up, bool extended)
        {
            keyboard.SendKeys(new int[] { CuaRdp.Native.BootstrapKeyboard.KeyData(scanCode, up, extended) });
        }

        private bool FocusInputCapture()
        {
            IntPtr input = IntPtr.Zero;
            EnumChildWindows(Handle, delegate(IntPtr child, IntPtr state)
            {
                var title = new System.Text.StringBuilder(256);
                GetWindowText(child, title, title.Capacity);
                if (title.ToString() != "Input Capture Window") return true;
                input = child;
                return false;
            }, IntPtr.Zero);
            if (input == IntPtr.Zero) return false;
            SetFocus(input);
            return GetFocus() == input;
        }

        internal void RequestEnterAnswer()
        {
            if (securityFlavor == "send-enter") answerTimer.Start();
            // Authentication prompts may contain sensitive information; never capture them.
        }

        private readonly Timer captureTimer = new Timer();
        private readonly Timer keyTimer = new Timer();
        private int keyStage;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);

        private void CaptureSurface(object sender, EventArgs args)
        {
            captureTimer.Stop();
            try
            {
                using (var bitmap = new Bitmap(Size.Width, Size.Height))
                {
                    bool captured = false;
                    try
                    {
                        var origin = PointToScreen(Point.Empty);
                        using (var graphics = Graphics.FromImage(bitmap))
                        {
                            graphics.CopyFromScreen(origin.X, origin.Y, 0, 0, bitmap.Size);
                        }
                        captured = true;
                    }
                    catch (Exception) { }
                    if (!captured)
                    {
                        using (var graphics = Graphics.FromImage(bitmap))
                        {
                            IntPtr context = graphics.GetHdc();
                            try { PrintWindow(Handle, context, 0x00000002); }
                            finally { graphics.ReleaseHdc(context); }
                        }
                    }
                    bitmap.Save(logPath + ".png", System.Drawing.Imaging.ImageFormat.Png);
                }
                Log("captured surface to " + logPath + ".png");
            }
            catch (Exception exception) { Log("capture failed: " + exception.GetBaseException().Message); }
        }

        internal void Fail(Exception exception)
        {
            result = 1;
            Log("error " + exception.GetBaseException().Message);
            Close();
        }

        protected override void OnFormClosed(FormClosedEventArgs args)
        {
            lock (logGate) { File.AppendAllText(logPath, "{\"result\":" + result.ToString(CultureInfo.InvariantCulture) + "}\n"); }
            base.OnFormClosed(args);
        }
    }
}
