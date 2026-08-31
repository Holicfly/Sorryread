using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace ReadAI;

public partial class LoginWindow : Window
{
    private readonly string _url;

    public LoginWindow(string url)
    {
        InitializeComponent();
        _url = url;
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, AppPaths.WebViewDataDirectory);
            await BrowserView.EnsureCoreWebView2Async(environment);
            BrowserView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            BrowserView.CoreWebView2.Navigate(_url);
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(this, $"内置浏览器初始化失败：{exception.Message}", "素若阅读", MessageBoxButton.OK, MessageBoxImage.Error);
            Close();
        }
    }

    private void ParseClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void CloseClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
