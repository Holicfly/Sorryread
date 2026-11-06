using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace ReadAI;

public static class ArticleDocumentFactory
{
    private const double DefaultLineSpacing = 1.2;

    public static FlowDocument Create(string text, string fontFamily, double fontSize, System.Windows.Media.Brush foreground,
        bool plainText = false)
    {
        double lineHeight = fontSize * DefaultLineSpacing;
        FlowDocument document = new()
        {
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = foreground,
            PagePadding = new Thickness(4, 2, 12, 20),
            FontFamily = new System.Windows.Media.FontFamily(fontFamily),
            FontSize = fontSize,
            FontWeight = FontWeights.Normal,
            FontStyle = FontStyles.Normal,
            LineHeight = lineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight
        };

        foreach (string blockText in SplitBlocks(plainText ? text : CleanText(text)))
        {
            // All lines, including paragraph boundaries, use the same fixed line height.
            Paragraph paragraph = new()
            {
                Margin = new Thickness(0),
                Padding = new Thickness(0),
                BorderThickness = new Thickness(0),
                Background = System.Windows.Media.Brushes.Transparent,
                TextIndent = 0,
                LineHeight = lineHeight,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight
            };
            string[] lines = blockText.Replace("\r\n", "\n", StringComparison.Ordinal)
                .Replace('\r', '\n')
                .Split('\n');
            for (int index = 0; index < lines.Length; index++)
            {
                if (index > 0)
                {
                    paragraph.Inlines.Add(new LineBreak());
                }
                paragraph.Inlines.Add(new Run(NormalizeLine(lines[index])));
            }
            document.Blocks.Add(paragraph);
        }

        return document;
    }

    private static string CleanText(string text)
    {
        string decoded = WebUtility.HtmlDecode(text);
        // Leave ordinary plain text (including comparison symbols) out of the HTML parser.
        if (!Regex.IsMatch(decoded, @"</?[a-zA-Z][^>]*>|<!--", RegexOptions.None, TimeSpan.FromSeconds(1)))
        {
            return decoded;
        }

        HtmlParser parser = new();
        using var document = parser.ParseDocument(string.Empty);
        var nodes = parser.ParseFragment(decoded, document.CreateElement("div"));
        StringBuilder plainText = new();
        foreach (var node in nodes)
        {
            AppendPlainText(node, plainText);
        }
        return plainText.ToString();
    }

    private static void AppendPlainText(INode node, StringBuilder text)
    {
        if (node is IText literal)
        {
            text.Append(literal.Data);
            return;
        }
        if (node is not IElement element) return;

        // Discard non-content subtrees, not just their opening and closing tags.
        if (element.LocalName is "script" or "style" or "template" or "head") return;
        if (element.LocalName is "br" or "hr")
        {
            text.Append('\n');
            return;
        }

        bool isBlock = element.LocalName is "p" or "div" or "section" or "article"
            or "blockquote" or "pre" or "li" or "ul" or "ol" or "tr" or "table"
            or "h1" or "h2" or "h3" or "h4" or "h5" or "h6";
        if (isBlock) AppendParagraphBoundary(text);
        foreach (var child in element.ChildNodes)
        {
            AppendPlainText(child, text);
        }
        if (isBlock) AppendParagraphBoundary(text);
    }

    private static void AppendParagraphBoundary(StringBuilder text)
    {
        if (text.Length == 0) return;
        if (text[^1] != '\n') text.Append('\n');
        if (text.Length < 2 || text[^2] != '\n') text.Append('\n');
    }

    private static string NormalizeLine(string text)
    {
        StringBuilder normalized = new();
        bool previousWasWhitespace = false;
        foreach (char character in text.Trim())
        {
            if (char.IsWhiteSpace(character))
            {
                if (!previousWasWhitespace) normalized.Append(' ');
                previousWasWhitespace = true;
            }
            else
            {
                normalized.Append(character);
                previousWasWhitespace = false;
            }
        }
        return normalized.ToString();
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
