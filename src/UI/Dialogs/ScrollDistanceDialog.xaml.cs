using System.Globalization;
using System.Windows;

namespace ReadAI;

public partial class ScrollDistanceDialog : Window
{
    public int ScrollDistance { get; private set; }

    public ScrollDistanceDialog(int currentValue)
    {
        InitializeComponent();
        LinesInput.Text = currentValue.ToString(CultureInfo.InvariantCulture);
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        LinesInput.Focus();
        LinesInput.SelectAll();
    }

    private void ConfirmClick(object sender, RoutedEventArgs e)
    {
        // Validate the entire input, including pasted text; signs and decimals are rejected.
        if (!int.TryParse(LinesInput.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int lines)
            || lines < ReaderSettings.MinimumScrollDistance || lines > ReaderSettings.MaximumScrollDistance)
        {
            ErrorText.Text = "请输入 1–10 范围内的正整数。";
            ErrorText.Visibility = Visibility.Visible;
            LinesInput.Focus();
            LinesInput.SelectAll();
            return;
        }
        ScrollDistance = lines;
        DialogResult = true;
    }
}
