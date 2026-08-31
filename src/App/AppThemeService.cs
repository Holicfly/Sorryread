using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace ReadAI;

public sealed class AppThemeService : IDisposable
{
    private const string PersonalizeRegistryPath = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeValue = "AppsUseLightTheme";
    private const int DwmUseImmersiveDarkMode = 20;
    private const int DwmUseImmersiveDarkModeBefore20H1 = 19;
    private bool _isInitialized;

    public static AppThemeService Current { get; } = new();

    public string Preference { get; private set; } = "System";
    public bool IsDarkTheme { get; private set; }

    public event EventHandler? ThemeChanged;

    private AppThemeService()
    {
    }

    public void Initialize(string preference)
    {
        Preference = NormalizePreference(preference);
        ApplyEffectiveTheme();
        if (_isInitialized) return;

        SystemEvents.UserPreferenceChanged += SystemEventsUserPreferenceChanged;
        _isInitialized = true;
    }

    public void SetPreference(string preference)
    {
        Preference = NormalizePreference(preference);
        ApplyEffectiveTheme();
    }

    private void SystemEventsUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (!string.Equals(Preference, "System", StringComparison.OrdinalIgnoreCase)) return;

        System.Windows.Application.Current?.Dispatcher.BeginInvoke(new Action(ApplyEffectiveTheme));
    }

    private void ApplyEffectiveTheme()
    {
        bool useDark = string.Equals(Preference, "Dark", StringComparison.OrdinalIgnoreCase) ||
                       (string.Equals(Preference, "System", StringComparison.OrdinalIgnoreCase) && IsSystemDarkTheme());
        IsDarkTheme = useDark;

        ResourceDictionary themeDictionary = new()
        {
            Source = new Uri(
                useDark
                    ? "pack://application:,,,/assets/themes/Dark.xaml"
                    : "pack://application:,,,/assets/themes/Light.xaml",
                UriKind.Absolute)
        };

        var dictionaries = System.Windows.Application.Current.Resources.MergedDictionaries;
        int existingIndex = -1;
        for (int index = 0; index < dictionaries.Count; index++)
        {
            string source = dictionaries[index].Source?.OriginalString ?? string.Empty;
            if (source.EndsWith("assets/themes/Light.xaml", StringComparison.OrdinalIgnoreCase) ||
                source.EndsWith("assets/themes/Dark.xaml", StringComparison.OrdinalIgnoreCase))
            {
                existingIndex = index;
                break;
            }
        }

        if (existingIndex >= 0)
        {
            dictionaries[existingIndex] = themeDictionary;
        }
        else
        {
            dictionaries.Insert(0, themeDictionary);
        }

        ThemeChanged?.Invoke(this, EventArgs.Empty);

        foreach (Window window in System.Windows.Application.Current.Windows)
        {
            ApplyWindowChrome(window);
        }
    }

    public void ApplyWindowChrome(Window window)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            window.SourceInitialized -= WindowSourceInitialized;
            window.SourceInitialized += WindowSourceInitialized;
            return;
        }

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763)) return;

        int enabled = IsDarkTheme ? 1 : 0;
        try
        {
            int result = DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref enabled, sizeof(int));
            if (result != 0)
            {
                DwmSetWindowAttribute(handle, DwmUseImmersiveDarkModeBefore20H1, ref enabled, sizeof(int));
            }
        }
        catch (DllNotFoundException)
        {
            // Content theming remains available when DWM APIs are unavailable.
        }
    }

    private void WindowSourceInitialized(object? sender, EventArgs e)
    {
        if (sender is not Window window) return;
        window.SourceInitialized -= WindowSourceInitialized;
        ApplyWindowChrome(window);
    }

    private static bool IsSystemDarkTheme()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(PersonalizeRegistryPath);
            object? value = key?.GetValue(AppsUseLightThemeValue);
            return value is int lightTheme && lightTheme == 0;
        }
        catch
        {
            return false;
        }
    }

    private static string NormalizePreference(string preference)
        => preference is "Light" or "Dark" ? preference : "System";

    public void Dispose()
    {
        if (!_isInitialized) return;
        SystemEvents.UserPreferenceChanged -= SystemEventsUserPreferenceChanged;
        _isInitialized = false;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr windowHandle,
        int attribute,
        ref int attributeValue,
        int attributeSize);
}
