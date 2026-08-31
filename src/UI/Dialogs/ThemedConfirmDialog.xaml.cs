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
