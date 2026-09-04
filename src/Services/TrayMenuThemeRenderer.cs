using System.Drawing.Drawing2D;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ReadAI;

internal sealed class TrayMenuThemeRenderer : Forms.ToolStripRenderer
{
    internal const float CornerRadius = 9;
    internal const float LogicalDpi = 96;
    private const float ItemCornerRadius = 8;
    private readonly Drawing.Color _background;
    private readonly Drawing.Color _selection;
    private readonly Drawing.Color _border;
    private readonly Drawing.Color _separator;

    public TrayMenuThemeRenderer(Drawing.Color background, Drawing.Color selection,
        Drawing.Color border, Drawing.Color separator)
    {
        _background = background;
        _selection = selection;
        _border = border;
        _separator = separator;
    }

    protected override void OnRenderToolStripBackground(Forms.ToolStripRenderEventArgs e)
        => FillRounded(e.Graphics, e.ToolStrip.ClientRectangle,
            CornerRadius * e.ToolStrip.DeviceDpi / LogicalDpi, _background);

    protected override void OnRenderToolStripBorder(Forms.ToolStripRenderEventArgs e)
    {
        float scale = e.ToolStrip.DeviceDpi / LogicalDpi;
        float inset = scale / 2;
        Drawing.RectangleF bounds = new(inset, inset,
            e.ToolStrip.Width - scale, e.ToolStrip.Height - scale);
        using GraphicsPath path = CreateRoundedPath(bounds, CornerRadius * scale);
        using Drawing.Pen pen = new(_border, scale);
        GraphicsState state = e.Graphics.Save();
        try
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.DrawPath(pen, path);
        }
        finally { e.Graphics.Restore(state); }
    }

    protected override void OnRenderMenuItemBackground(Forms.ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Enabled || (!e.Item.Selected && !e.Item.Pressed)) return;
        float scale = (e.ToolStrip?.DeviceDpi ?? (int)LogicalDpi) / LogicalDpi;
        Drawing.RectangleF bounds = new(0, 0, e.Item.Width, e.Item.Height);
        FillRounded(e.Graphics, bounds, ItemCornerRadius * scale, _selection);
    }

    protected override void OnRenderItemText(Forms.ToolStripItemTextRenderEventArgs e)
    {
        float scale = (e.ToolStrip?.DeviceDpi ?? (int)LogicalDpi) / LogicalDpi;
        int inset = (int)Math.Round(RoundedTrayMenu.TextInset * scale);
        Drawing.Rectangle bounds = new(inset, 0, Math.Max(1, e.Item.Width - inset * 2), e.Item.Height);
        // 不沿用默认菜单的文字偏移，按完整行高居中，hover/按下均保留主题文字色。
        Forms.TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, bounds, e.Item.ForeColor,
            Forms.TextFormatFlags.Left | Forms.TextFormatFlags.VerticalCenter |
            Forms.TextFormatFlags.SingleLine | Forms.TextFormatFlags.NoPadding |
            Forms.TextFormatFlags.EndEllipsis);
    }

    protected override void OnRenderSeparator(Forms.ToolStripSeparatorRenderEventArgs e)
    {
        float scale = (e.ToolStrip?.DeviceDpi ?? (int)LogicalDpi) / LogicalDpi;
        float inset = 8 * scale;
        float middle = e.Item.Height / 2f;
        using Drawing.Pen pen = new(_separator, scale);
        e.Graphics.DrawLine(pen, inset, middle, e.Item.Width - inset, middle);
    }

    private static void FillRounded(Drawing.Graphics graphics, Drawing.RectangleF bounds,
        float radius, Drawing.Color color)
    {
        using GraphicsPath path = CreateRoundedPath(bounds, radius);
        using Drawing.SolidBrush brush = new(color);
        GraphicsState state = graphics.Save();
        try
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.FillPath(brush, path);
        }
        finally { graphics.Restore(state); }
    }

    internal static GraphicsPath CreateRoundedPath(Drawing.RectangleF bounds, float radius)
    {
        GraphicsPath path = new();
        if (bounds.Width <= 0 || bounds.Height <= 0) return path;
        float diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
