using System.Reflection;
using System.Windows;
using System.Windows.Input;

namespace ReadAI;

public enum InformationDialogPage
{
    Guide,
    Shortcuts,
    About
}

internal sealed record GuideItem(string Text);
internal sealed record ShortcutItem(string Keys, string Action, string Scope);

public partial class InformationDialog : Window
{
    public InformationDialog(InformationDialogPage page)
    {
        InitializeComponent();
        ConfigurePage(page);
    }

    public static void ShowDialogFor(Window owner, InformationDialogPage page)
    {
        InformationDialog dialog = new(page) { Owner = owner };
        dialog.ShowDialog();
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        CloseButton.Focus();
        Keyboard.Focus(CloseButton);
    }

    private void ConfigurePage(InformationDialogPage page)
    {
        GuideItemsControl.Visibility = Visibility.Collapsed;
        ShortcutScrollViewer.Visibility = Visibility.Collapsed;
        AboutPanel.Visibility = Visibility.Collapsed;

        switch (page)
        {
            case InformationDialogPage.Guide:
                Height = 300;
                Title = "素若阅读 使用说明";
                DialogTitleText.Text = "使用说明";
                DialogSubtitleText.Text = "核心功能快速上手";
                GuideItemsControl.ItemsSource = new GuideItem[]
                {
                    new("输入网址可解析文章；小说搜索默认聚合全部书源。"),
                    new("阅读时可用上下章按钮、目录和方向键切章或整屏滚动。"),
                    new("通过搜索进入的书会记录最近阅读，也可加入收藏。"),
                    new("阅读正文时按 F12 进入或退出透明阅读。")
                };
                GuideItemsControl.Visibility = Visibility.Visible;
                break;
            case InformationDialogPage.Shortcuts:
                Height = 380;
                Title = "素若阅读 快捷键";
                DialogTitleText.Text = "快捷键";
                DialogSubtitleText.Text = "全局操作与阅读窗口按键";
                ShortcutItemsControl.ItemsSource = new ShortcutItem[]
                {
                    new("Shift + F", "上一章", "应用获得焦点且存在上一章时生效"),
                    new("Shift + J", "下一章", "应用获得焦点且存在下一章时生效"),
                    new("Shift + E", "隐藏或恢复应用", "全局；主窗口与透明窗口均可用"),
                    new("Alt + M", "隐藏或恢复应用", "全局；左右 Alt 均可用"),
                    new("↑ / ↓", "向上或向下整屏滚动", "阅读窗口获得焦点时生效"),
                    new("← / →", "上一章或下一章", "阅读窗口获得焦点且章节存在时生效"),
                    new("F12", "进入或退出透明阅读", "仅阅读状态；透明模式下始终可退出")
                };
                ShortcutScrollViewer.Visibility = Visibility.Visible;
                break;
            default:
                Height = 300;
                Title = "关于素若阅读";
                DialogTitleText.Text = "关于";
                DialogSubtitleText.Text = "轻量、专注的 Windows 阅读器";
                Version? version = Assembly.GetExecutingAssembly().GetName().Version;
                VersionText.Text = $"版本 {version?.ToString(3) ?? "1.0.4"}";
                AboutPanel.Visibility = Visibility.Visible;
                break;
        }
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

    private void CloseClick(object sender, RoutedEventArgs e)
        => Close();

    private void DialogPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        e.Handled = true;
        Close();
    }
}
