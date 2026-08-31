using System.Text;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace ReadAI;

public static class ArticleDocumentFactory
{
    public static FlowDocument Create(string text, string fontFamily, double fontSize, System.Windows.Media.Brush foreground)
    {
        FlowDocument document = new()
        {
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = foreground,
            PagePadding = new Thickness(4, 2, 12, 20),
            FontFamily = new System.Windows.Media.FontFamily(fontFamily),
            FontSize = fontSize
        };

        foreach (string blockText in SplitBlocks(text))
        {
            Paragraph paragraph = new() { Margin = new Thickness(0, 0, 0, 14) };
            string[] lines = blockText.Replace("\r\n", "\n", StringComparison.Ordinal)
                .Replace('\r', '\n')
                .Split('\n');
            for (int index = 0; index < lines.Length; index++)
            {
                if (index > 0)
                {
                    paragraph.Inlines.Add(new LineBreak());
                }
                paragraph.Inlines.Add(new Run(lines[index]));
            }
            document.Blocks.Add(paragraph);
        }

        return document;
    }

    private static IReadOnlyList<string> SplitBlocks(string text)
    {
        List<string> blocks = new();
        StringBuilder current = new();
        foreach (string rawLine in text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(rawLine))
            {
                if (current.Length > 0)
                {
                    blocks.Add(current.ToString().TrimEnd());
                    current.Clear();
                }
                continue;
            }

            if (current.Length > 0)
            {
                current.AppendLine();
            }
            current.Append(rawLine.Trim());
        }

        if (current.Length > 0)
        {
            blocks.Add(current.ToString().TrimEnd());
        }

        return blocks.Count > 0 ? blocks : new[] { text };
    }
}
