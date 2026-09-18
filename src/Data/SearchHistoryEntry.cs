namespace ReadAI;

public static class SearchHistoryModes
{
    public const string Aggregated = "aggregated";
    public const string Legacy18Mh = "legacy18mh";
    public const string Wodushu = BookSourceCatalog.WodushuId;

    public static void Validate(string mode)
    {
        if (mode is not (Aggregated or Legacy18Mh) && !BookSourceCatalog.InputSources.Any(source => source.Id == mode))
        {
            throw new ArgumentException("Unknown search history mode.", nameof(mode));
        }
    }
}

public sealed record SearchHistoryEntry(string Mode, string Keyword)
{
    public string DisplayName { get; init; } = string.Empty;
    public string DisplayText => string.IsNullOrWhiteSpace(DisplayName) ? Keyword : DisplayName;
}
