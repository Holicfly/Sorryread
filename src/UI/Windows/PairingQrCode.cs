using System.Collections;
using System.Windows;
using System.Windows.Media;
using QRCoder;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using Pen = System.Windows.Media.Pen;
using Point = System.Windows.Point;
using Rect = System.Windows.Rect;

namespace ReadAI;

/// <summary>
/// Builds the pairing code as a frozen vector drawing so the compact window keeps hard module
/// edges at every scale instead of the uneven pixels produced by scaling a small bitmap.
/// Modules stay square; only the three finder patterns are softened, which decoders tolerate
/// because their scan lines still cross a one-module ring and a three-module core.
/// </summary>
public static class PairingQrCode
{
    private const int FinderModules = 7;
    private const double FinderRadius = 1.5;
    private const double CoreRadius = 0.9;

    private static readonly Brush Ink = Frozen(new SolidColorBrush(Color.FromRgb(0x11, 0x11, 0x11)));
    private static readonly Brush Paper = Frozen(new SolidColorBrush(Colors.White));
    private static readonly Pen FinderRing = Frozen(new Pen(Ink, 1));

    /// <summary>Encoded grid plus the drawing built from it. The quiet zone is part of the grid.</summary>
    public sealed class Code(DrawingImage image, int gridSize, bool[] modules, int quietZone)
    {
        public DrawingImage Image { get; } = image;
        public int GridSize { get; } = gridSize;
        public int QuietZone { get; } = quietZone;
        public bool Has(int column, int row) => modules[row * GridSize + column];
    }

    public static Code Create(string payload)
    {
        using QRCodeData data = QRCodeGenerator.GenerateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        return Create(data.ModuleMatrix);
    }

    public static Code Create(IReadOnlyList<BitArray> matrix)
    {
        int grid = matrix.Count;
        var modules = new bool[grid * grid];
        for (int row = 0; row < grid; row++)
            for (int column = 0; column < grid; column++)
                modules[row * grid + column] = matrix[row][column];

        int quiet = QuietZoneModules(modules, grid);
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(Paper, null, new RectangleGeometry(new Rect(0, 0, grid, grid))));
        drawing.Children.Add(new GeometryDrawing(Ink, null, BodyGeometry(modules, grid, quiet)));
        drawing.Children.Add(new GeometryDrawing(null, FinderRing, FinderGeometry(quiet, grid, 0.5, FinderModules - 1, FinderRadius)));
        drawing.Children.Add(new GeometryDrawing(Ink, null, FinderGeometry(quiet, grid, 2, 3, CoreRadius)));
        drawing.Freeze();

        var image = new DrawingImage(drawing);
        image.Freeze();
        return new Code(image, grid, modules, quiet);
    }

    /// <summary>Quiet zone width, derived from the top-left module of the grid.</summary>
    private static int QuietZoneModules(bool[] modules, int grid)
    {
        for (int row = 0; row < grid; row++)
            for (int column = 0; column < grid; column++)
                if (modules[row * grid + column]) return Math.Min(row, column);
        return 0;
    }

    private static Geometry BodyGeometry(bool[] modules, int grid, int quiet)
    {
        var geometry = new StreamGeometry();
        using (StreamGeometryContext context = geometry.Open())
        {
            for (int row = 0; row < grid; row++)
            {
                for (int column = 0; column < grid; column++)
                {
                    if (!modules[row * grid + column] || IsFinder(column, row, grid, quiet)) continue;
                    context.BeginFigure(new Point(column, row), true, true);
                    context.LineTo(new Point(column + 1, row), false, false);
                    context.LineTo(new Point(column + 1, row + 1), false, false);
                    context.LineTo(new Point(column, row + 1), false, false);
                }
            }
        }
        geometry.Freeze();
        return geometry;
    }

    /// <summary>Rounded square in module units, one shape per finder pattern.</summary>
    private static Geometry FinderGeometry(int quiet, int grid, double inset, double side, double radius)
    {
        var geometry = new GeometryGroup();
        foreach ((int x, int y) in FinderOrigins(quiet, grid))
            geometry.Children.Add(new RectangleGeometry(new Rect(x + inset, y + inset, side, side), radius, radius));
        geometry.Freeze();
        return geometry;
    }

    private static IEnumerable<(int X, int Y)> FinderOrigins(int quiet, int grid)
    {
        int far = grid - quiet - FinderModules;
        return [(quiet, quiet), (far, quiet), (quiet, far)];
    }

    private static bool IsFinder(int column, int row, int grid, int quiet)
    {
        int far = grid - quiet - FinderModules;
        bool Inside(int x, int y) => column >= x && column < x + FinderModules && row >= y && row < y + FinderModules;
        return Inside(quiet, quiet) || Inside(far, quiet) || Inside(quiet, far);
    }

    private static T Frozen<T>(T value) where T : Freezable
    {
        value.Freeze();
        return value;
    }
}
