namespace ReadAI;

public static class SearchHistoryModes
{
    public const string Aggregated = "aggregated";
    public const string Legacy18Mh = "legacy18mh";

    public static void Validate(string mode)
    {
        if (mode is not (Aggregated or Legacy18Mh))
        {
            throw new ArgumentException("Unknown search history mode.", nameof(mode));
        }
    }
}

public sealed record SearchHistoryEntry(string Mode, string Keyword);
