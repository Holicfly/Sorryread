using DrawingColor = System.Drawing.Color;
using Forms = System.Windows.Forms;

namespace ReadAI;

internal sealed class TrayMenuThemeRenderer : Forms.ToolStripProfessionalRenderer
{
    public TrayMenuThemeRenderer(
        DrawingColor background,
        DrawingColor selection,
        DrawingColor border,
        DrawingColor separator)
        : base(new TrayMenuColorTable(background, selection, border, separator))
    {
        RoundedEdges = false;
    }

    private sealed class TrayMenuColorTable : Forms.ProfessionalColorTable
    {
        private readonly DrawingColor _background;
        private readonly DrawingColor _selection;
        private readonly DrawingColor _border;
        private readonly DrawingColor _separator;

        public TrayMenuColorTable(
            DrawingColor background,
            DrawingColor selection,
            DrawingColor border,
            DrawingColor separator)
        {
            UseSystemColors = false;
            _background = background;
            _selection = selection;
            _border = border;
            _separator = separator;
        }

        public override DrawingColor ToolStripDropDownBackground => _background;
        public override DrawingColor ImageMarginGradientBegin => _background;
        public override DrawingColor ImageMarginGradientMiddle => _background;
        public override DrawingColor ImageMarginGradientEnd => _background;
        public override DrawingColor MenuItemSelected => _selection;
        public override DrawingColor MenuItemSelectedGradientBegin => _selection;
        public override DrawingColor MenuItemSelectedGradientEnd => _selection;
        public override DrawingColor MenuItemPressedGradientBegin => _selection;
        public override DrawingColor MenuItemPressedGradientMiddle => _selection;
        public override DrawingColor MenuItemPressedGradientEnd => _selection;
        public override DrawingColor MenuItemBorder => _border;
        public override DrawingColor MenuBorder => _border;
        public override DrawingColor ToolStripBorder => _border;
        public override DrawingColor SeparatorDark => _separator;
        public override DrawingColor SeparatorLight => _separator;
    }
}
