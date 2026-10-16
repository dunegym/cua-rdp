using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;

namespace CuaRdp.Native
{
    // Diagnostic replica of RdpWindow's watch-window lifecycle. It never creates the RDP
    // ActiveX control and never connects; it exists to reproduce shell behavior around the
    // style changes, the first minimize-to-park transition and the taskbar/tray presence.
    // The style constants, BecomeWatchWindow, the Resize park handler, ParkOffScreen and the
    // parked-keeper reassertion must mirror native/RdpWindow.cs exactly; drift here makes the
    // probe meaningless. Output is one JSON object exposed through the Report property.
    public sealed class WatchProbe : Form
    {
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", EntryPoint = "IsChild")] private static extern bool IsChildWindow(IntPtr parent, IntPtr window);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)] private static extern int SetWindowLong(IntPtr window, int index, int value);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

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
        private const uint WM_SYSCOMMAND = 0x0112;
        private static readonly IntPtr SC_MINIMIZE = new IntPtr(0xF020);

        private const string TitlePrefix = "cua-rdp child session";
        private const string TitleText = TitlePrefix + " - watch probe (diagnostic, never connects)";

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

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SetCurrentProcessExplicitAppUserModelID(string appId);

        private readonly bool interactiveVariant;
        private readonly string strategy;
        private readonly bool traceMessages = Environment.GetEnvironmentVariable("CUA_RDP_PROBE_TRACE") != null;
        private readonly List<Dictionary<string, object>> phases = new List<Dictionary<string, object>>();
        private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        private readonly DateTime started = DateTime.UtcNow;
        private bool watchApplied;
        private bool parked;
        private bool parkPending;
        private bool closingProbe;
        private NotifyIcon trayIcon;
        private Rectangle lastOnScreenBounds;
        private string report;
        private string fatal;
        private string closingReason;

        public string Report { get { return report ?? ""; } }
        public static string DumpedButtons = "";

        public WatchProbe(bool interactiveVariant) : this(interactiveVariant, "none") { }

        public WatchProbe(bool interactiveVariant, string strategy)
        {
            this.interactiveVariant = interactiveVariant;
            this.strategy = strategy;
            // A dedicated app id keeps the probe out of the console host's taskbar group, so
            // the taskbar button (if any) carries this window's title and UIA can match it.
            SetCurrentProcessExplicitAppUserModelID("CuaRdp.WatchProbe");
            Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs args)
            {
                fatal = "thread: " + args.Exception.GetBaseException().ToString();
                timer.Stop();
                Close();
            };
            AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs args)
            {
                fatal = "domain: " + args.ExceptionObject;
            };
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            StartPosition = FormStartPosition.Manual;
            MinimizeBox = false;
            MaximizeBox = false;
            ClientSize = new Size(320, 200);
            Text = TitleText;
            var screen = SystemInformation.VirtualScreen;
            if (interactiveVariant)
            {
                var area = Screen.PrimaryScreen.WorkingArea;
                Location = new Point(area.Left + 32, area.Top + 32);
            }
            else
            {
                Location = new Point(screen.Right + 64, screen.Top);
            }
            Resize += delegate
            {
                try
                {
                    // The park must not mutate WindowState re-entrantly inside the WM_SIZE that
                    // the minimize itself is producing; defer it to the next safe dispatch.
                    if (watchApplied && WindowState == FormWindowState.Minimized && !parkPending)
                    {
                        parkPending = true;
                        BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                    }
                }
                catch (Exception exception)
                {
                    phases.Add(new Dictionary<string, object> { { "phase", "resize-error" }, { "error", exception.GetBaseException().ToString() } });
                    throw;
                }
            };
            Activated += delegate
            {
                Console.Error.WriteLine("[probe] Activated parked=" + parked + " at " + (long)(DateTime.UtcNow - started).TotalMilliseconds + "ms");
                if (watchApplied && parked) RestoreWatchWindow();
            };
            FormClosing += delegate(object sender, FormClosingEventArgs args)
            {
                Console.Error.WriteLine("[probe] FormClosing reason=" + args.CloseReason + " watchApplied=" + watchApplied + " parked=" + parked);
                // Mirrors production: user closes AND external closes park instead of closing,
                // deferred out of the WM_CLOSE dispatch.
                if (!closingProbe && watchApplied && (args.CloseReason == CloseReason.UserClosing || args.CloseReason == CloseReason.TaskManagerClosing))
                {
                    args.Cancel = true;
                    if (!parkPending)
                    {
                        parkPending = true;
                        BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                    }
                }
                else closingProbe = true;
            };
            timer.Interval = 800;
            timer.Tick += Step;
            timer.Start();
        }

        protected override bool ShowWithoutActivation { get { return !interactiveVariant; } }

        // Mirrors the production WndProc interception: user-driven minimize/close system
        // commands park directly instead of ever reaching DefWndProc.
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == (int)WM_SYSCOMMAND_MSG && watchApplied && !closingProbe)
            {
                long command = message.WParam.ToInt64() & 0xFFF0;
                if (command == 0xF020 || command == 0xF060)
                {
                    Console.Error.WriteLine("[probe] intercepted SYSCOMMAND " + Convert.ToString(command, 16));
                    if (!parkPending)
                    {
                        parkPending = true;
                        BeginInvoke(new Action(delegate { parkPending = false; ParkOffScreen(); }));
                    }
                    return;
                }
            }
            TraceAndBase(ref message);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams settings = base.CreateParams;
                if (!interactiveVariant) settings.ExStyle |= 0x08000080;
                return settings;
            }
        }

        private void Step(object sender, EventArgs args)
        {
            try
            {
                RunStep();
            }
            catch (Exception exception)
            {
                var entry = new Dictionary<string, object>();
                entry["phase"] = "step-error";
                entry["error"] = exception.GetBaseException().ToString();
                phases.Add(entry);
                fatal = fatal ?? entry["error"] as string;
                timer.Stop();
                Close();
                return;
            }
            finally
            {
                // Mirrors the keeper tick: a parked watch window is kept off-screen, unless the
                // user has it foreground on-screen (a restore the Activated handler missed).
                if (watchApplied && parked)
                {
                    var screen = SystemInformation.VirtualScreen;
                    if (Location.X < screen.Right)
                    {
                        IntPtr foreground = GetForegroundWindow();
                        if (foreground != IntPtr.Zero && (foreground == Handle || IsChildWindow(Handle, foreground))) parked = false;
                        else Location = new Point(screen.Right + 64, screen.Top);
                    }
                }
            }
        }

        private const uint WM_SYSCOMMAND_MSG = 0x0112;
        private const uint WM_SIZE_MSG = 0x0005;
        private const uint WM_ACTIVATE_MSG = 0x0006;

        // Mirrors the production WndProc interception (see the override near ShowWithoutActivation).
        private void TraceAndBase(ref Message message)
        {
            if (traceMessages)
            {
                if (message.Msg == (int)WM_SYSCOMMAND_MSG)
                    Console.Error.WriteLine("[probe] WM_SYSCOMMAND " + Convert.ToString(message.WParam.ToInt64(), 16));
                else if (message.Msg == (int)WM_SIZE_MSG)
                    Console.Error.WriteLine("[probe] WM_SIZE " + message.WParam + " at " + (long)(DateTime.UtcNow - started).TotalMilliseconds + "ms");
                else if (message.Msg == (int)WM_ACTIVATE_MSG)
                    Console.Error.WriteLine("[probe] WM_ACTIVATE " + message.WParam + " at " + (long)(DateTime.UtcNow - started).TotalMilliseconds + "ms");
            }
            base.WndProc(ref message);
        }

        private int scenarioStep;

        private void RunStep()
        {
            int step = scenarioStep;
            scenarioStep++;
            switch (step)
            {
                case 0:
                    Record("baseline");
                    return;
                case 1:
                    BecomeWatchWindow();
                    Record("watch");
                    return;
                case 2:
                    Record("watch-settled");
                    return;
                case 3:
                    // A title-bar minimize click: WM_SYSCOMMAND/SC_MINIMIZE. The WndProc
                    // interception must park without the window ever becoming iconic.
                    PostMessage(Handle, WM_SYSCOMMAND_MSG, new IntPtr(0xF020), IntPtr.Zero);
                    return;
                case 4:
                    Record("min-parked");
                    return;
                case 5:
                    // The taskbar button click: the shell activates the parked window. A
                    // background probe process can be denied SetForegroundWindow by the
                    // foreground lock (the real shell never is), so fall back to SC_RESTORE.
                    bool activated = SetForegroundWindow(Handle);
                    Console.Error.WriteLine("[probe] SetForegroundWindow=" + activated);
                    if (!activated) PostMessage(Handle, WM_SYSCOMMAND_MSG, new IntPtr(0xF120), IntPtr.Zero);
                    return;
                case 6:
                    // A settling tick: activation-driven restore may complete asynchronously.
                    return;
                case 7:
                    Record("taskbar-restored");
                    return;
                case 8:
                    // A title-bar X click: WM_SYSCOMMAND/SC_CLOSE, intercepted into a park.
                    PostMessage(Handle, WM_SYSCOMMAND_MSG, new IntPtr(0xF060), IntPtr.Zero);
                    return;
                case 9:
                    Record("close-parked");
                    return;
                case 10:
                    // An external close (taskbar right-click "Close window"): bare WM_CLOSE,
                    // which WinForms reports as TaskManagerClosing; it must park, not close.
                    PostMessage(Handle, 0x0010, IntPtr.Zero, IntPtr.Zero);
                    return;
                case 11:
                    Record("external-close-parked");
                    return;
                case 12:
                    // The tray double-click restore path.
                    RestoreWatchWindow();
                    Record("tray-restored");
                    return;
                default:
                    timer.Stop();
                    closingProbe = true;
                    Close();
                    return;
            }
        }

        // Mirrors RdpWindow.BecomeWatchWindow.
        private void BecomeWatchWindow()
        {
            if (watchApplied) return;
            watchApplied = true;
            Text = TitleText;
            if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
            parked = false;
            var area = Screen.PrimaryScreen.WorkingArea;
            ClientSize = new Size(Math.Min(ClientSize.Width, area.Width - 64), Math.Min(ClientSize.Height, area.Height - 64));
            Location = new Point(area.Left + 32, area.Top + 32);
            lastOnScreenBounds = new Rectangle(Location, Size);
            IntPtr handle = Handle;
            SetWindowLong(handle, GWL_STYLE, GetWindowLong(handle, GWL_STYLE) | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_THICKFRAME);
            SetWindowLong(handle, GWL_EXSTYLE, (GetWindowLong(handle, GWL_EXSTYLE) & ~(WS_EX_NOACTIVATE_STYLE | WS_EX_TOOLWINDOW)) | WS_EX_APPWINDOW);
            SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
            SetWindowAppUserModelId(handle, "CuaRdp.WatchProbe.Window");
            // Registration strategies under test: Win11's taskbar may only register buttons on
            // show/activation events, not on in-place ex-style changes.
            if (strategy == "hide-show")
            {
                IntPtr before = Handle;
                Hide();
                Show();
                if (Handle != before) throw new InvalidOperationException("hide-show recreated the handle");
            }
            else if (strategy == "activate")
            {
                Activate();
            }
        }

        // Mirrors RdpWindow.ParkOffScreen.
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
            if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
            Location = new Point(screen.Right + 64, screen.Top);
            if (trayIcon == null)
            {
                trayIcon = new NotifyIcon();
                trayIcon.Icon = SystemIcons.Application;
                trayIcon.Text = "cua-rdp child session";
                trayIcon.Visible = true;
            }
        }

        // Mirrors RdpWindow.RestoreWatchWindow.
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

        private void Record(string phase)
        {
            var entry = new Dictionary<string, object>();
            entry["phase"] = phase;
            entry["ms"] = (long)(DateTime.UtcNow - started).TotalMilliseconds;
            Console.Error.WriteLine("[probe] phase " + phase + " at " + entry["ms"] + "ms");
            bool button = false;
            bool tray = false;
            if (Environment.GetEnvironmentVariable("CUA_RDP_PROBE_NO_UIA") == null)
            {
                // UIA enumeration must not run on a thread that owns a window: the provider side
                // answers through this thread's message pump, which is blocked inside the call.
                bool buttonResult = false;
                bool trayResult = false;
                var worker = new Thread(delegate()
                {
                    buttonResult = TaskbarHasButton();
                    trayResult = TrayIconListed();
                    // An empty dump means the enumeration itself hiccuped (no taskbar buttons at
                    // all is impossible); retry once so a sampling glitch cannot fake a verdict.
                    if (DumpedButtons.Length == 0)
                    {
                        Thread.Sleep(400);
                        buttonResult = TaskbarHasButton();
                    }
                });
                worker.IsBackground = true;
                var begin = DateTime.UtcNow;
                worker.Start();
                if (!worker.Join(TimeSpan.FromSeconds(12))) { entry["uiaTimeout"] = true; }
                entry["uiaMs"] = (long)(DateTime.UtcNow - begin).TotalMilliseconds;
                button = buttonResult;
                tray = trayResult;
                entry["buttonNames"] = DumpedButtons;
            }
            else
            {
                entry["uiaSkipped"] = true;
            }
            entry["button"] = button;
            entry["tray"] = tray;
            entry["visible"] = Visible;
            entry["iconic"] = IsIconic(Handle);
            entry["style"] = "0x" + GetWindowLong(Handle, GWL_STYLE).ToString("X8", CultureInfo.InvariantCulture);
            entry["exStyle"] = "0x" + GetWindowLong(Handle, GWL_EXSTYLE).ToString("X8", CultureInfo.InvariantCulture);
            entry["x"] = Location.X;
            entry["y"] = Location.Y;
            entry["parked"] = parked;
            entry["watchApplied"] = watchApplied;
            phases.Add(entry);
        }

        protected override void OnFormClosing(FormClosingEventArgs args)
        {
            closingReason = args.CloseReason.ToString();
            base.OnFormClosing(args);
        }

        protected override void OnFormClosed(FormClosedEventArgs args)
        {
            if (trayIcon != null) { trayIcon.Visible = false; trayIcon.Dispose(); trayIcon = null; }
            var entry = new Dictionary<string, object>();
            entry["phase"] = "closed";
            entry["closeReason"] = closingReason ?? "";
            phases.Add(entry);
            var payload = new Dictionary<string, object>();
            payload["variant"] = interactiveVariant ? "interactive" : "background";
            payload["strategy"] = strategy;
            payload["phases"] = phases;
            if (fatal != null) payload["fatal"] = fatal;
            if (DumpedButtons.Length != 0) payload["taskbarButtons"] = DumpedButtons;
            report = new JavaScriptSerializer().Serialize(payload);
            base.OnFormClosed(args);
        }

        private static bool TaskbarHasButton()
        {
            DumpedButtons = "";
            try
            {
                var condition = new PropertyCondition(AutomationElement.ClassNameProperty, "Shell_TrayWnd");
                foreach (AutomationElement bar in AutomationElement.RootElement.FindAll(TreeScope.Children, condition))
                {
                    var buttons = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
                    foreach (AutomationElement button in bar.FindAll(TreeScope.Descendants, buttons))
                    {
                        string name = button.Current.Name;
                        if (name != null) DumpedButtons += name.Replace('\n', ' ').Replace('\r', ' ') + " | ";
                        if (name != null && name.StartsWith(TitlePrefix, StringComparison.Ordinal)) return true;
                    }
                }
            }
            catch (Exception exception) { DumpedButtons += "error: " + exception.GetBaseException().Message; return false; }
            return false;
        }

        private static bool TrayIconListed()
        {
            try
            {
                var prefix = "cua-rdp";
                var bars = AutomationElement.RootElement.FindAll(TreeScope.Children,
                    new PropertyCondition(AutomationElement.ClassNameProperty, "Shell_TrayWnd"));
                foreach (AutomationElement bar in bars)
                {
                    foreach (AutomationElement button in bar.FindAll(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)))
                    {
                        string name = button.Current.Name;
                        if (name != null && name.IndexOf(prefix, StringComparison.Ordinal) >= 0) return true;
                    }
                }
                var overflow = AutomationElement.RootElement.FindAll(TreeScope.Children,
                    new PropertyCondition(AutomationElement.ClassNameProperty, "NotifyIconOverflowWindow"));
                foreach (AutomationElement window in overflow)
                {
                    foreach (AutomationElement button in window.FindAll(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)))
                    {
                        string name = button.Current.Name;
                        if (name != null && name.IndexOf(prefix, StringComparison.Ordinal) >= 0) return true;
                    }
                }
            }
            catch (Exception) { return false; }
            return false;
        }
    }
}
