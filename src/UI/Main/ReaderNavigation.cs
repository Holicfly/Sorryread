namespace ReadAI;

public enum ReaderView
{
    Home,
    SearchResults,
    Reader,
    Library
}

/// <summary>Tracks valid view return targets without retaining obsolete books or search sessions.</summary>
public sealed class ReaderNavigation
{
    private readonly List<ReaderView> _backStack = [];
    public ReaderView Current { get; private set; } = ReaderView.Home;
    public bool CanGoBack => _backStack.Count > 0;

    public void GoHome()
    {
        _backStack.Clear();
        Current = ReaderView.Home;
    }

    public void Navigate(ReaderView target)
    {
        if (Current == target) return;
        // Only the current book/search session is retained by MainWindow. Drop stale targets.
        Forget(target);
        _backStack.Add(Current);
        Current = target;
    }

    public void Forget(ReaderView target) => _backStack.RemoveAll(view => view == target);

    public bool TryGoBack(out ReaderView target)
    {
        target = Current;
        if (_backStack.Count == 0) return false;
        target = _backStack[^1];
        _backStack.RemoveAt(_backStack.Count - 1);
        Current = target;
        return true;
    }
}
