namespace ReadAI.Sync;

public sealed record LocalBookPolicy(string Sha256, string Revision, int Epoch, bool Removed,
    bool DesktopExcluded, bool PhoneExcluded, int ResetEpoch);

public sealed record LocalBookPolicyRequest(string Id, string Action, int Epoch);
public sealed record LocalBookCatalogUnit(int Index, string Title, string Address);
