using System.Drawing.Drawing2D;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ReadAI;

// 保留 ContextMenuStrip 的键盘导航、Esc 和自动关闭，只替换轮廓与排版。
internal sealed class RoundedTrayMenu : Forms.ContextMenuStrip
{
    private readonly Drawing.Font _menuFont = new("Segoe UI", 9F);
    private const int ScreenGap = 8;
    private const int RowHeight = 28;
    private const int SeparatorHeight = 9;
    internal const int TextInset = 12;
    private bool _arrangingItems;

    public RoundedTrayMenu()
    {
        Font = _menuFont;
        ShowCheckMargin = false;
        ShowImageMargin = false;
        DropShadowEnabled = true;
        AutoSize = false;
        ApplySpacing();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplySpacing();
        UpdateOutline();
    }

    protected override void OnItemAdded(Forms.ToolStripItemEventArgs e)
    {
        base.OnItemAdded(e);
        ApplyItemSpacing(e.Item);
    }

    protected override void OnDpiChangedAfterParent(EventArgs e)
    {
        base.OnDpiChangedAfterParent(e);
        ApplySpacing();
        UpdateOutline();
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateOutline();
    }

    protected override void OnLayout(Forms.LayoutEventArgs e)
    {
        if (_arrangingItems) return;
        _arrangingItems = true;
        try
        {
            // 菜单宽度只取实际文字加两侧留白，条目命中区与绘制区使用同一个完整宽度。
            Forms.ToolStripItem[] items = Items.Cast<Forms.ToolStripItem>().Where(item => item.Available).ToArray();
            int textWidth = items.Where(item => item is not Forms.ToolStripSeparator)
                .Select(item => Forms.TextRenderer.MeasureText(item.Text, item.Font,
                    Drawing.Size.Empty, Forms.TextFormatFlags.SingleLine | Forms.TextFormatFlags.NoPadding).Width)
                .DefaultIfEmpty(0).Max();
            int rowWidth = Math.Max(1, textWidth + Scale(TextInset) * 2);
            int height = items.Sum(item => Scale(item is Forms.ToolStripSeparator ? SeparatorHeight : RowHeight));
            foreach (Forms.ToolStripItem item in items)
                item.Size = new Drawing.Size(rowWidth, Scale(item is Forms.ToolStripSeparator ? SeparatorHeight : RowHeight));
            ClientSize = new Drawing.Size(rowWidth + Padding.Horizontal, height + Padding.Vertical);
            base.OnLayout(e);
            int top = Padding.Top;
            foreach (Forms.ToolStripItem item in items)
            {
                int itemHeight = Scale(item is Forms.ToolStripSeparator ? SeparatorHeight : RowHeight);
                item.Size = new Drawing.Size(rowWidth, itemHeight);
                SetItemLocation(item, new Drawing.Point(Padding.Left, top));
                top += itemHeight;
            }
        }
        finally { _arrangingItems = false; }
    }

    protected override void OnOpened(EventArgs e)
    {
        // 在系统选定的弹出方向上再留一点间距，同时确保整张菜单处于可用屏幕内。
        Drawing.Point cursor = Forms.Cursor.Position;
        Drawing.Rectangle area = Forms.Screen.FromPoint(cursor).WorkingArea;
        int gap = Scale(ScreenGap);
        int left = Left + (cursor.X < Left + Width / 2 ? gap : -gap);
        int top = Top + (cursor.Y < Top + Height / 2 ? gap : -gap);
        Location = new Drawing.Point(
            Math.Clamp(left, area.Left + gap, Math.Max(area.Left + gap, area.Right - Width - gap)),
            Math.Clamp(top, area.Top + gap, Math.Max(area.Top + gap, area.Bottom - Height - gap)));
        base.OnOpened(e);
    }

    private int Scale(int value) => (int)Math.Round(value * DeviceDpi / TrayMenuThemeRenderer.LogicalDpi);

    private void ApplySpacing()
    {
        Padding = new Forms.Padding(Scale(4));
        MinimumSize = Drawing.Size.Empty;
        foreach (Forms.ToolStripItem item in Items) ApplyItemSpacing(item);
        PerformLayout();
    }

    private void ApplyItemSpacing(Forms.ToolStripItem? item)
    {
        if (item is null) return;
        item.AutoSize = false;
        item.Margin = Forms.Padding.Empty;
        item.Padding = new Forms.Padding(Scale(TextInset), 0, Scale(TextInset), 0);
        item.TextAlign = Drawing.ContentAlignment.MiddleLeft;
    }

    private void UpdateOutline()
    {
        if (Width <= 0 || Height <= 0) return;
        using GraphicsPath path = TrayMenuThemeRenderer.CreateRoundedPath(ClientRectangle,
            TrayMenuThemeRenderer.CornerRadius * DeviceDpi / TrayMenuThemeRenderer.LogicalDpi);
        Drawing.Region? previous = Region;
        Region = new Drawing.Region(path);
        previous?.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            Drawing.Region? outline = Region;
            Region = null;
            outline?.Dispose();
        }
        base.Dispose(disposing);
        if (disposing) _menuFont.Dispose();
    }
}
