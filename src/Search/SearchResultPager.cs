namespace ReadAI;

/// <summary>Splits each cached server page into at most 20 results, retaining server-page boundaries.</summary>
public sealed class SearchResultPager
{
    public const int PageSize = 20;
    private sealed record ServerPage(IReadOnlyList<NovelSearchResult> Results, bool HasNext);
    private readonly SortedDictionary<int, ServerPage> _pages = [];
    public int PageNumber { get; private set; } = 1;
    public int LoadedPageCount => _pages.Values.Sum(page => SliceCount(page.Results.Count));
    public int NextServerPageNumber => _pages.Count == 0 ? 1 : _pages.Keys.Last() + 1;
    public bool HasPrevious => PageNumber > 1;
    public bool HasNext => PageNumber < LoadedPageCount || (_pages.Count > 0 && _pages.Values.Last().HasNext);
    public int CurrentServerPageNumber => LocateCurrentPage().ServerNumber;
    public IReadOnlyList<NovelSearchResult> VisibleResults
    {
        get
        {
            var location = LocateCurrentPage();
            return _pages.TryGetValue(location.ServerNumber, out ServerPage? page)
                ? page.Results.Skip(location.SliceIndex * PageSize).Take(PageSize).ToList()
                : [];
        }
    }

    public void Store(int serverPageNumber, IReadOnlyList<NovelSearchResult> results, bool hasNext)
    {
        if (serverPageNumber < 1) throw new ArgumentOutOfRangeException(nameof(serverPageNumber));
        _pages[serverPageNumber] = new ServerPage(results.ToArray(), hasNext);
        PageNumber = Math.Clamp(PageNumber, 1, Math.Max(1, LoadedPageCount));
    }

    public void SelectServerPage(int serverPageNumber)
    {
        if (!_pages.ContainsKey(serverPageNumber)) return;
        PageNumber = 1 + _pages.Where(page => page.Key < serverPageNumber).Sum(page => SliceCount(page.Value.Results.Count));
    }

    public void ResetToFirst() => PageNumber = 1;

    public bool MovePrevious()
    {
        if (!HasPrevious) return false;
        PageNumber--;
        return true;
    }

    public bool MoveNextCached()
    {
        if (PageNumber >= LoadedPageCount) return false;
        PageNumber++;
        return true;
    }

    public void Clear()
    {
        _pages.Clear();
        PageNumber = 1;
    }

    private (int ServerNumber, int SliceIndex) LocateCurrentPage()
    {
        int remaining = PageNumber - 1;
        foreach (var page in _pages)
        {
            int slices = SliceCount(page.Value.Results.Count);
            if (remaining < slices) return (page.Key, remaining);
            remaining -= slices;
        }
        return (1, 0);
    }

    private static int SliceCount(int count) => Math.Max(1, (count + PageSize - 1) / PageSize);
}
