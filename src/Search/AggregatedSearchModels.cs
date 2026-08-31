namespace ReadAI;

public enum BookSourceSearchStatus
{
    Pending,
    Searching,
    Succeeded,
    Empty,
    Failed
}

public sealed class BookSourceSearchState
{
    public BookSourceDefinition Source { get; init; } = new();
    public BookSourceSearchStatus Status { get; set; }
    public List<NovelSearchResult> Results { get; set; } = [];
    public string ErrorMessage { get; set; } = string.Empty;
    public int PageNumber { get; set; } = 1;
    public string NextPageUrl { get; set; } = string.Empty;

    public int ResultCount => Results.Count;

    public BookSourceSearchState Snapshot()
        => new()
        {
            Source = Source,
            Status = Status,
            Results = [.. Results],
            ErrorMessage = ErrorMessage,
            PageNumber = PageNumber,
            NextPageUrl = NextPageUrl
        };
}

public sealed class BookSourceSearchTab
{
    public string SourceId { get; init; } = string.Empty;
    public string DisplayText { get; init; } = string.Empty;
    public string ToolTip { get; init; } = string.Empty;
    public bool IsSelected { get; init; }
    public bool IsFailed { get; init; }

    public static BookSourceSearchTab FromState(BookSourceSearchState state, bool isSelected)
    {
        string displayText = state.Status switch
        {
            BookSourceSearchStatus.Pending => state.Source.Name,
            BookSourceSearchStatus.Searching => $"{state.Source.Name}（搜索中）",
            BookSourceSearchStatus.Succeeded => $"{state.Source.Name}（{state.ResultCount}）",
            BookSourceSearchStatus.Empty => $"{state.Source.Name}（0）",
            BookSourceSearchStatus.Failed => $"{state.Source.Name}（失败）",
            _ => state.Source.Name
        };
        string toolTip = state.Status == BookSourceSearchStatus.Failed
            ? $"{state.Source.Name}：{(string.IsNullOrWhiteSpace(state.ErrorMessage) ? "搜索失败" : state.ErrorMessage)}"
            : displayText;

        return new BookSourceSearchTab
        {
            SourceId = state.Source.Id,
            DisplayText = displayText,
            ToolTip = toolTip,
            IsSelected = isSelected,
            IsFailed = state.Status == BookSourceSearchStatus.Failed
        };
    }
}
