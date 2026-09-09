using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace ReadAI;

public sealed class HotKeyService : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const uint VkM = 0x4D;
    private const uint VkE = 0x45;
    private const uint VkF = 0x46;
    private const uint VkJ = 0x4A;
    private const uint VkVolumeUp = 0xAF;
    private const uint VkVolumeDown = 0xAE;
    private readonly HashSet<uint> _volumeKeysDown = new();
    private readonly HashSet<uint> _volumeKeysHandled = new();
    public Func<bool>? CanHandleVolumeKeys { get; set; }
    public Action<bool, bool>? VolumeKeyPressed { get; set; }
    private const uint VkMenu = 0x12;
    private const uint VkLMenu = 0xA4;
    private const uint VkRMenu = 0xA5;
    private const uint VkShift = 0x10;
    private const uint VkLShift = 0xA0;
    private const uint VkRShift = 0xA1;
    private const uint LlkhfExtended = 0x00000001;

    private readonly LowLevelKeyboardProc _keyboardHookCallback;
    private IntPtr _hookHandle;
    private Dispatcher? _dispatcher;
    private bool _leftAltDown;
    private bool _rightAltDown;
    private bool _genericShiftDown;
    private bool _leftShiftDown;
    private bool _rightShiftDown;
    private bool _mKeyHandled;
    private bool _eKeyHandled;
    private bool _fKeyHandled;
    private bool _jKeyHandled;

    public event EventHandler? HotKeyPressed;
    public event EventHandler? NextChapterPressed;
    public event EventHandler? PreviousChapterPressed;
    public bool ChapterShortcutsEnabled { get; set; } = true;

    public HotKeyService()
    {
        _keyboardHookCallback = KeyboardHookCallback;
    }

    public bool Register(Window window)
    {
        _dispatcher = window.Dispatcher;
        IntPtr moduleHandle = GetModuleHandle(null);
        _hookHandle = SetWindowsHookEx(WhKeyboardLl, _keyboardHookCallback, moduleHandle, 0);
        return _hookHandle != IntPtr.Zero;
    }

    private IntPtr KeyboardHookCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0)
        {
            return CallNextHookEx(_hookHandle, code, wParam, lParam);
        }

        int message = wParam.ToInt32();
        bool isKeyDown = message is WmKeyDown or WmSysKeyDown;
        bool isKeyUp = message is WmKeyUp or WmSysKeyUp;
        KeyboardHookData data = Marshal.PtrToStructure<KeyboardHookData>(lParam);

        if (data.VirtualKeyCode is VkVolumeUp or VkVolumeDown)
        {
            bool eligible = IsApplicationForeground && CanHandleVolumeKeys?.Invoke() == true;
            if (isKeyUp)
            {
                _volumeKeysDown.Remove(data.VirtualKeyCode);
                bool wasHandled = _volumeKeysHandled.Remove(data.VirtualKeyCode);
                if (eligible && wasHandled) return new IntPtr(1);
            }
            else if (isKeyDown)
            {
                bool repeat = !_volumeKeysDown.Add(data.VirtualKeyCode);
                if (eligible)
                {
                    _volumeKeysHandled.Add(data.VirtualKeyCode);
                    IntPtr target = GetForegroundWindow();
                    bool down = data.VirtualKeyCode == VkVolumeUp;
                    // Keep the hook short. Recheck focus before dispatching to avoid scrolling
                    // a different window after focus changes while the callback is queued.
                    _dispatcher?.BeginInvoke(new Action(() =>
                    {
                        if (GetForegroundWindow() == target && CanHandleVolumeKeys?.Invoke() == true)
                            VolumeKeyPressed?.Invoke(down, repeat);
                    }));
                    return new IntPtr(1);
                }
            }
            return CallNextHookEx(_hookHandle, code, wParam, lParam);
        }

        if (data.VirtualKeyCode is VkLMenu or VkMenu)
        {
            bool isRightAlt = data.VirtualKeyCode == VkMenu && (data.Flags & LlkhfExtended) != 0;
            if (isRightAlt) _rightAltDown = isKeyDown ? true : isKeyUp ? false : _rightAltDown;
            else _leftAltDown = isKeyDown ? true : isKeyUp ? false : _leftAltDown;
        }
        else if (data.VirtualKeyCode == VkRMenu)
        {
            _rightAltDown = isKeyDown ? true : isKeyUp ? false : _rightAltDown;
        }
        else if (data.VirtualKeyCode == VkShift)
        {
            _genericShiftDown = isKeyDown ? true : isKeyUp ? false : _genericShiftDown;
        }
        else if (data.VirtualKeyCode == VkLShift)
        {
            _leftShiftDown = isKeyDown ? true : isKeyUp ? false : _leftShiftDown;
        }
        else if (data.VirtualKeyCode == VkRShift)
        {
            _rightShiftDown = isKeyDown ? true : isKeyUp ? false : _rightShiftDown;
        }
        else if (data.VirtualKeyCode == VkM)
        {
            if (TryHandleChord(
                    isKeyDown,
                    isKeyUp,
                    _leftAltDown || _rightAltDown,
                    ref _mKeyHandled,
                    () => HotKeyPressed?.Invoke(this, EventArgs.Empty)))
            {
                return new IntPtr(1);
            }
        }
        else if (data.VirtualKeyCode == VkE)
        {
            if (TryHandleChord(
                    isKeyDown,
                    isKeyUp,
                    IsShiftDown,
                    ref _eKeyHandled,
                    () => HotKeyPressed?.Invoke(this, EventArgs.Empty)))
            {
                return new IntPtr(1);
            }
        }
        else if (data.VirtualKeyCode == VkF)
        {
            if (TryHandleChord(
                    isKeyDown,
                    isKeyUp,
                    IsShiftDown && ChapterShortcutsEnabled && IsApplicationForeground,
                    ref _fKeyHandled,
                    () =>
                    {
                        if (ChapterShortcutsEnabled && IsApplicationForeground)
                        {
                            PreviousChapterPressed?.Invoke(this, EventArgs.Empty);
                        }
                    }))
            {
                return new IntPtr(1);
            }
        }
        else if (data.VirtualKeyCode == VkJ)
        {
            if (TryHandleChord(
                    isKeyDown,
                    isKeyUp,
                    IsShiftDown && ChapterShortcutsEnabled && IsApplicationForeground,
                    ref _jKeyHandled,
                    () =>
                    {
                        if (ChapterShortcutsEnabled && IsApplicationForeground)
                        {
                            NextChapterPressed?.Invoke(this, EventArgs.Empty);
                        }
                    }))
            {
                return new IntPtr(1);
            }
        }

        return CallNextHookEx(_hookHandle, code, wParam, lParam);
    }

    private bool IsShiftDown => _genericShiftDown || _leftShiftDown || _rightShiftDown;

    // Alt+M/Shift+E remain global; chapter shortcuts are limited to this foreground process.
    private static bool IsApplicationForeground
    {
        get
        {
            IntPtr foregroundWindow = GetForegroundWindow();
            if (foregroundWindow == IntPtr.Zero) return false;

            GetWindowThreadProcessId(foregroundWindow, out uint foregroundProcessId);
            return foregroundProcessId == GetCurrentProcessId();
        }
    }

    private bool TryHandleChord(
        bool isKeyDown,
        bool isKeyUp,
        bool modifierDown,
        ref bool keyHandled,
        Action callback)
    {
        if (isKeyDown && modifierDown && !keyHandled)
        {
            keyHandled = true;
            _dispatcher?.BeginInvoke(callback);
            return true;
        }

        if (isKeyDown && keyHandled)
        {
            return true;
        }

        if (!isKeyUp || !keyHandled) return false;
        keyHandled = false;
        return true;
    }

    public void Dispose()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
        _dispatcher = null;
    }

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardHookData
    {
        public uint VirtualKeyCode;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();
}
