using System.Windows;

namespace ReadAI;

public partial class ThemedConfirmDialog : Window
{
    public ThemedConfirmDialog(string title, string message, string confirmText = "确认")
    {
        InitializeComponent();
        Title = title;
        TitleText.Text = title;
        MessageText.Text = message;
        ConfirmButton.Content = confirmText;
    }

    public static bool Show(
        Window owner,
        string title,
        string message,
        string confirmText = "确认")
    {
        ThemedConfirmDialog dialog = new(title, message, confirmText)
        {
            Owner = owner
        };
        return dialog.ShowDialog() == true;
    }

    public static ThemedConfirmDialog ForPairing(string deviceName)
    {
        var dialog = new ThemedConfirmDialog("连接设备",
            $"“{deviceName}”请求连接。\n允许后自动同步收藏、最近阅读与全部阅读进度。", "允许连接")
        {
            Width = 360
        };
        dialog.DialogFrame.Padding = new Thickness(16);
        dialog.TitleText.FontSize = 16;
        dialog.MessageText.Margin = new Thickness(0, 10, 0, 16);
        dialog.ConfirmButton.SetResourceReference(StyleProperty, "AccentButtonStyle");
        dialog.CancelButton.Content = "暂不连接";
        return dialog;
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        CancelButton.Focus();
        System.Windows.Input.Keyboard.Focus(CancelButton);
    }

    private void ConfirmClick(object sender, RoutedEventArgs e)
        => DialogResult = true;

    private void CancelClick(object sender, RoutedEventArgs e)
        => DialogResult = false;

    private void DialogPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != System.Windows.Input.Key.Escape) return;
        e.Handled = true;
        DialogResult = false;
    }
}
