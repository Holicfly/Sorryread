using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Point = System.Windows.Point;
using Button = System.Windows.Controls.Button;

namespace ReadAI;

public partial class ColorPickerDialog : Window
{
    private const double FullHue = 360.0;
    private const int DialogAnimationMilliseconds = 180;
    private readonly PresetColorOption[] _presetColors;
    private double _hue;
    private double _saturation;
    private double _value;
    private bool _isDraggingSaturationValue;
    private bool _isDraggingHue;
    private bool _isSynchronizingHexText;

    public string SelectedHexColor { get; private set; } = "#252525";

    public ColorPickerDialog(Color initialColor)
    {
        InitializeComponent();
        _presetColors =
        [
            new("墨黑", "#252525"),
            new("深灰", "#4F4F4F"),
            new("中灰", "#8A8A8A"),
            new("浅灰", "#D0D0D0"),
            new("柔白", "#E7E9EC"),
            new("米白", "#F3E8D0"),
            new("浅蓝", "#9ED0FF"),
            new("浅绿", "#A7E3B2"),
            new("暖橙", "#FFD09E"),
            new("淡紫", "#D5B8FF"),
            new("柔粉", "#FFB7C5"),
            new("青灰", "#B8E3DC")
        ];
        PresetColorsItemsControl.ItemsSource = _presetColors;
        SetSelectedColor(initialColor, updateHexText: true);
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        HexTextBox.Focus();
        Keyboard.Focus(HexTextBox);
        HexTextBox.SelectAll();
    }

    private void DialogLoaded(object sender, RoutedEventArgs e)
    {
        CubicEase easing = new() { EasingMode = EasingMode.EaseOut };
        DialogRoot.BeginAnimation(
            OpacityProperty,
            new DoubleAnimation(1, TimeSpan.FromMilliseconds(DialogAnimationMilliseconds))
            {
                EasingFunction = easing
            });
        if (DialogRoot.RenderTransform is TranslateTransform transform)
        {
            transform.BeginAnimation(
                TranslateTransform.YProperty,
                new DoubleAnimation(0, TimeSpan.FromMilliseconds(DialogAnimationMilliseconds))
                {
                    EasingFunction = easing
                });
        }

        Dispatcher.BeginInvoke(UpdateSelectionCursors, DispatcherPriority.Loaded);
    }

    private void HeaderMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed) return;
        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void PresetColorClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string hex } && TryParseHexColor(hex, out Color color))
        {
            SetSelectedColor(color, updateHexText: true);
        }
    }

    private void SaturationValueMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _isDraggingSaturationValue = SaturationValuePanel.CaptureMouse();
        UpdateSaturationValue(e.GetPosition(SaturationValuePanel));
        e.Handled = true;
    }

    private void SaturationValueMouseMove(object sender, MouseEventArgs e)
    {
        if (!_isDraggingSaturationValue || e.LeftButton != MouseButtonState.Pressed) return;
        UpdateSaturationValue(e.GetPosition(SaturationValuePanel));
    }

    private void SaturationValueMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_isDraggingSaturationValue) return;
        UpdateSaturationValue(e.GetPosition(SaturationValuePanel));
        SaturationValuePanel.ReleaseMouseCapture();
        _isDraggingSaturationValue = false;
        e.Handled = true;
    }

    private void SaturationValueLostMouseCapture(object sender, MouseEventArgs e)
        => _isDraggingSaturationValue = false;

    private void HueMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _isDraggingHue = HuePanel.CaptureMouse();
        UpdateHue(e.GetPosition(HuePanel));
        e.Handled = true;
    }

    private void HueMouseMove(object sender, MouseEventArgs e)
    {
        if (!_isDraggingHue || e.LeftButton != MouseButtonState.Pressed) return;
        UpdateHue(e.GetPosition(HuePanel));
    }

    private void HueMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_isDraggingHue) return;
        UpdateHue(e.GetPosition(HuePanel));
        HuePanel.ReleaseMouseCapture();
        _isDraggingHue = false;
        e.Handled = true;
    }

    private void HueLostMouseCapture(object sender, MouseEventArgs e)
        => _isDraggingHue = false;

    private void UpdateSaturationValue(Point point)
    {
        double width = Math.Max(1, SaturationValuePanel.ActualWidth);
        double height = Math.Max(1, SaturationValuePanel.ActualHeight);
        _saturation = Math.Clamp(point.X / width, 0, 1);
        _value = Math.Clamp(1 - point.Y / height, 0, 1);
        UpdateSelectedColorFromHsv();
    }

    private void UpdateHue(Point point)
    {
        double width = Math.Max(1, HuePanel.ActualWidth);
        double ratio = Math.Clamp(point.X / width, 0, 1);
        _hue = Math.Min(Math.BitDecrement(FullHue), ratio * FullHue);
        UpdateHueBase();
        UpdateSelectedColorFromHsv();
    }

    private void HexTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_isSynchronizingHexText) return;
        if (!TryParseHexColor(HexTextBox.Text, out Color color))
        {
            SetHexValidationState(isValid: false);
            return;
        }

        SetSelectedColor(color, updateHexText: false);
    }

    private void HexTextBoxLostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (TryParseHexColor(HexTextBox.Text, out _)) return;
        SynchronizeHexText();
        SetHexValidationState(isValid: true);
    }

    private void ConfirmClick(object sender, RoutedEventArgs e)
    {
        if (!TryParseHexColor(HexTextBox.Text, out Color color))
        {
            SetHexValidationState(isValid: false);
            HexTextBox.Focus();
            HexTextBox.SelectAll();
            return;
        }

        SetSelectedColor(color, updateHexText: true);
        DialogResult = true;
    }

    private void CancelClick(object sender, RoutedEventArgs e)
        => DialogResult = false;

    private void CloseClick(object sender, RoutedEventArgs e)
        => DialogResult = false;

    private void DialogPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        e.Handled = true;
        DialogResult = false;
    }

    private void SetSelectedColor(Color color, bool updateHexText)
    {
        RgbToHsv(color, out _hue, out _saturation, out _value);
        UpdateHueBase();
        UpdateSelectedPresentation(color, updateHexText);
        UpdateSelectionCursors();
    }

    private void UpdateSelectedColorFromHsv()
    {
        Color color = HsvToColor(_hue, _saturation, _value);
        UpdateSelectedPresentation(color, updateHexText: true);
        UpdateSelectionCursors();
    }

    private void UpdateSelectedPresentation(Color color, bool updateHexText)
    {
        SelectedHexColor = ToHex(color);
        SelectedColorPreview.Background = new SolidColorBrush(color);
        foreach (PresetColorOption preset in _presetColors)
        {
            preset.IsSelected = string.Equals(preset.Hex, SelectedHexColor, StringComparison.OrdinalIgnoreCase);
        }

        if (updateHexText)
        {
            SynchronizeHexText();
        }
        SetHexValidationState(isValid: true);
    }

    private void SynchronizeHexText()
    {
        _isSynchronizingHexText = true;
        HexTextBox.Text = SelectedHexColor;
        HexTextBox.CaretIndex = HexTextBox.Text.Length;
        _isSynchronizingHexText = false;
    }

    private void SetHexValidationState(bool isValid)
    {
        ValidationText.Visibility = isValid ? Visibility.Hidden : Visibility.Visible;
        ConfirmButton.IsEnabled = isValid;
    }

    private void UpdateHueBase()
        => HueBaseBorder.Background = new SolidColorBrush(HsvToColor(_hue, 1, 1));

    private void UpdateSelectionCursors()
    {
        if (SaturationValuePanel.ActualWidth > 0 && SaturationValuePanel.ActualHeight > 0)
        {
            Canvas.SetLeft(
                SaturationValueCursor,
                Math.Clamp(
                    _saturation * SaturationValuePanel.ActualWidth - SaturationValueCursor.Width / 2,
                    0,
                    Math.Max(0, SaturationValuePanel.ActualWidth - SaturationValueCursor.Width)));
            Canvas.SetTop(
                SaturationValueCursor,
                Math.Clamp(
                    (1 - _value) * SaturationValuePanel.ActualHeight - SaturationValueCursor.Height / 2,
                    0,
                    Math.Max(0, SaturationValuePanel.ActualHeight - SaturationValueCursor.Height)));
        }

        if (HuePanel.ActualWidth > 0)
        {
            Canvas.SetLeft(
                HueCursor,
                Math.Clamp(
                    _hue / FullHue * HuePanel.ActualWidth - HueCursor.Width / 2,
                    0,
                    Math.Max(0, HuePanel.ActualWidth - HueCursor.Width)));
        }
    }

    private static bool TryParseHexColor(string value, out Color color)
    {
        string normalized = value.Trim();
        if (normalized.StartsWith('#')) normalized = normalized[1..];
        if (normalized.Length == 6 &&
            uint.TryParse(normalized, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out uint rgb))
        {
            color = Color.FromRgb(
                (byte)(rgb >> 16),
                (byte)(rgb >> 8),
                (byte)rgb);
            return true;
        }

        color = default;
        return false;
    }

    private static string ToHex(Color color)
        => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    private static void RgbToHsv(Color color, out double hue, out double saturation, out double value)
    {
        double red = color.R / 255.0;
        double green = color.G / 255.0;
        double blue = color.B / 255.0;
        double maximum = Math.Max(red, Math.Max(green, blue));
        double minimum = Math.Min(red, Math.Min(green, blue));
        double delta = maximum - minimum;

        if (delta <= double.Epsilon)
        {
            hue = 0;
        }
        else if (Math.Abs(maximum - red) <= double.Epsilon)
        {
            hue = 60 * (((green - blue) / delta) % 6);
        }
        else if (Math.Abs(maximum - green) <= double.Epsilon)
        {
            hue = 60 * ((blue - red) / delta + 2);
        }
        else
        {
            hue = 60 * ((red - green) / delta + 4);
        }

        if (hue < 0) hue += FullHue;
        saturation = maximum <= double.Epsilon ? 0 : delta / maximum;
        value = maximum;
    }

    private static Color HsvToColor(double hue, double saturation, double value)
    {
        hue = ((hue % FullHue) + FullHue) % FullHue;
        saturation = Math.Clamp(saturation, 0, 1);
        value = Math.Clamp(value, 0, 1);
        double chroma = value * saturation;
        double hueSection = hue / 60;
        double secondary = chroma * (1 - Math.Abs(hueSection % 2 - 1));
        (double red, double green, double blue) = hueSection switch
        {
            < 1 => (chroma, secondary, 0d),
            < 2 => (secondary, chroma, 0d),
            < 3 => (0d, chroma, secondary),
            < 4 => (0d, secondary, chroma),
            < 5 => (secondary, 0d, chroma),
            _ => (chroma, 0d, secondary)
        };
        double match = value - chroma;
        return Color.FromRgb(
            ToByte(red + match),
            ToByte(green + match),
            ToByte(blue + match));
    }

    private static byte ToByte(double component)
        => (byte)Math.Clamp(Math.Round(component * 255), byte.MinValue, byte.MaxValue);

    private sealed class PresetColorOption : INotifyPropertyChanged
    {
        private bool _isSelected;

        public PresetColorOption(string name, string hex)
        {
            Name = name;
            Hex = hex;
            Brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            Brush.Freeze();
        }

        public string Name { get; }
        public string Hex { get; }
        public SolidColorBrush Brush { get; }

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (_isSelected == value) return;
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
