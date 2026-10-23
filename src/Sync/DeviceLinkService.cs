using System.IO;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Makaretu.Dns;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Hosting;

namespace ReadAI.Sync;

public sealed record PairOffer(string Type, int Version, string ServerId, string Name,
    List<string> Endpoints, string CertificateSha256, string Token, string ExpiresUtc);
public sealed record PairRequest(string DeviceId, string Name, string Token);
public sealed record PairedDevice(string DeviceId, string Name, string CredentialHash);
public sealed record PushRequest(List<SyncChange> Changes);
public sealed record CompleteRequest(bool Record);

/// <summary>One paired client, application-owned HTTPS listener and DNS-SD advertisement.</summary>
public sealed class DeviceLinkService : IAsyncDisposable
{
    private readonly ReaderDatabase _database;
    private readonly string _directory;
    private readonly bool _allowLoopback;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _startGate = new(1, 1);
    private readonly Dictionary<string, SnapshotLease> _snapshots = [];
    private UploadLease? _upload;
    private WebApplication? _host;
    private X509Certificate2? _certificate;
    private PairedDevice? _peer;
    private string? _pairToken;
    private DateTime _pairExpires;
    private int _failedPairAttempts;
    private bool _pairBusy;
    private string? _receiptDevice, _receiptToken, _receiptCredential;
    private DateTime _receiptExpires;
    private DateTime _lastSeen;
    private MulticastService? _multicast;
    private ServiceDiscovery? _discovery;
    private ServiceProfile? _profile;
    private System.Threading.Timer? _statusTimer;
    private bool _lastReported;
    private volatile bool _disposed;
    private Task? _disposeTask;
    private sealed record SnapshotLease(string DeviceId, string CredentialHash, DateTime Expires,
        string Seq, List<SyncRecord> Records);
    private sealed class UploadLease(string id, PairedDevice peer, string seq)
    {
        public string Id = id, Seq = seq;
        public PairedDevice Peer = peer;
        public DateTime Expires = DateTime.UtcNow.AddMinutes(5);
        public List<SyncRecord> Records = [];
        public int Page, Bytes;
    }
    public sealed record UploadStart(string Seq);

    public DeviceLinkService(ReaderDatabase database, string directory, bool allowLoopback = false)
    {
        _database = database;
        _directory = directory;
        _allowLoopback = allowLoopback;
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "peer.dpapi");
        if (File.Exists(path)) _peer = SyncProtocol.Decode<PairedDevice>(Encoding.UTF8.GetString(Unprotect(File.ReadAllBytes(path))));
    }

    public Func<string, Task<bool>>? ConfirmPairingAsync { get; set; }
    public event EventHandler? StateChanged;
    public string? Error { get; private set; }
    public string ServerId => _database.SyncDeviceId;
    public int Port { get; private set; }
    public PairedDevice? Peer { get { lock (_gate) return _peer; } }
    public bool IsConnected { get { lock (_gate) return _host != null && _peer != null && DateTime.UtcNow - _lastSeen < TimeSpan.FromSeconds(40); } }
    public string CertificateSha256 => _certificate == null ? "" : Convert.ToHexString(SHA256.HashData(_certificate.RawData)).ToLowerInvariant();

    private static byte[] Unprotect(byte[] bytes) => ProtectedData.Unprotect(bytes, null, DataProtectionScope.CurrentUser);
    private static byte[] Protect(byte[] bytes) => ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
    private void SaveProtected(string name, byte[] bytes)
    {
        string path = Path.Combine(_directory, name);
        File.WriteAllBytes(path + ".new", Protect(bytes));
        File.Move(path + ".new", path, true);
    }
    private static string Secret() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    private static string Hash(string secret) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(secret))).ToLowerInvariant();
    private static bool SecretEquals(string left, string right) => CryptographicOperations.FixedTimeEquals(
        SHA256.HashData(Encoding.UTF8.GetBytes(left)), SHA256.HashData(Encoding.UTF8.GetBytes(right)));

    public static bool IsLocalAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        byte[] bytes = address.GetAddressBytes();
        return address.AddressFamily == AddressFamily.InterNetwork
            ? bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
            : address.IsIPv6LinkLocal || (bytes[0] & 0xfe) == 0xfc;
    }

    private List<IPAddress> LocalAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Any(g => !g.Address.Equals(IPAddress.Any) && !g.Address.Equals(IPAddress.IPv6Any)))
        .ThenBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 0 : 1)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses.OrderBy(a => a.Address.AddressFamily == AddressFamily.InterNetwork ? 0 : 1))
        .Select(a => a.Address)
        .Where(IsLocalAddress).Distinct().ToList();

    public List<string> Endpoints => PairingAddresses()
        .Select(a => new UriBuilder("https", a.ToString(), Port).Uri.GetLeftPart(UriPartial.Authority)).ToList();

    /// <summary>
    /// Addresses worth putting in a pairing code. IPv4 comes first because a link-local IPv6 URL
    /// without a zone index is not reachable from the phone, and every extra address lengthens the
    /// code the user has to scan. IPv6 is only used when the machine has no IPv4 address at all.
    /// </summary>
    private List<IPAddress> PairingAddresses()
    {
        List<IPAddress> addresses = LocalAddresses();
        List<IPAddress> ipv4 = addresses.Where(a => a.AddressFamily == AddressFamily.InterNetwork).ToList();
        return ipv4.Count > 0 ? ipv4.Take(3).ToList()
            : addresses.Where(a => a.AddressFamily == AddressFamily.InterNetworkV6 && !a.IsIPv6LinkLocal).Take(3).ToList();
    }

    private X509Certificate2 LoadCertificate()
    {
        string path = Path.Combine(_directory, "certificate.dpapi");
        if (File.Exists(path)) return new X509Certificate2(Unprotect(File.ReadAllBytes(path)), (string?)null,
            X509KeyStorageFlags.UserKeySet);
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Sorryread LAN Sync", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        var usage = new OidCollection { new("1.3.6.1.5.5.7.3.1") };
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usage, false));
        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName("sorryread.local"); san.AddIpAddress(IPAddress.Loopback);
        foreach (var address in LocalAddresses()) san.AddIpAddress(address);
        request.CertificateExtensions.Add(san.Build());
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));
        byte[] pfx = certificate.Export(X509ContentType.Pfx);
        SaveProtected("certificate.dpapi", pfx);
        // Windows Schannel cannot serve an EphemeralKeySet private key. Import into
        // the current user's temporary key container; the encrypted PFX stays DPAPI-protected.
        return new X509Certificate2(pfx, (string?)null, X509KeyStorageFlags.UserKeySet);
    }

    // Certificate/host/DNS initialization must never run on a WPF caller's thread.
    public Task StartAsync() => Task.Run(StartCoreAsync);

    private async Task StartCoreAsync()
    {
        await _startGate.WaitAsync().ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_host != null) return;
            _certificate ??= LoadCertificate();
            int preferredPort = ReadPort();
            var app = CreateHost(preferredPort);
            try { await app.StartAsync().ConfigureAwait(false); }
            catch (Exception error)
            {
                await app.DisposeAsync().ConfigureAwait(false);
                if (preferredPort == 0 || !PortInUse(error)) throw;
                // The saved port may belong to another application. Keep this pairing and
                // advertise a new endpoint rather than leave the connection service stopped.
                app = CreateHost(0);
                try { await app.StartAsync().ConfigureAwait(false); }
                catch { await app.DisposeAsync().ConfigureAwait(false); throw; }
            }
            string address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
            Port = new Uri(address).Port;
            _host = app;
            Error = null;
            SavePort();
            if (!_allowLoopback) StartAdvertisement();
            _statusTimer = new System.Threading.Timer(_ =>
            {
                bool current = IsConnected;
                if (current != _lastReported) { _lastReported = current; NotifyState(); }
            }, null, 0, 5000);
            NotifyState();
        }
        catch (Exception error)
        {
            Error = "局域网连接服务未能启动：" + error.Message;
            NotifyState(); throw;
        }
        finally { _startGate.Release(); }
    }

    private int ReadPort()
    {
        try
        {
            return int.TryParse(File.ReadAllText(Path.Combine(_directory, "port.txt")), NumberStyles.None,
                CultureInfo.InvariantCulture, out int port) && port is >= 1024 and <= 65535 ? port : 0;
        }
        catch (IOException) { return 0; }
        catch (UnauthorizedAccessException) { return 0; }
    }

    private void SavePort()
    {
        try
        {
            string path = Path.Combine(_directory, "port.txt");
            File.WriteAllText(path + ".new", Port.ToString(CultureInfo.InvariantCulture));
            File.Move(path + ".new", path, true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { Error = "连接端口未能保存，下次启动时可能需要重新发现电脑。"; }
    }

    private static bool PortInUse(Exception error)
    {
        for (Exception? current = error; current != null; current = current.InnerException)
            if (current is Microsoft.AspNetCore.Connections.AddressInUseException ||
                current is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse }) return true;
        return false;
    }

    private WebApplication CreateHost(int listenPort)
    {
        var certificate = _certificate ?? throw new InvalidOperationException("连接证书尚未初始化。");
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { ApplicationName = typeof(DeviceLinkService).Assembly.FullName });
        builder.Logging.ClearProviders(); // Never log QR tokens, headers, URLs or credentials.
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.Limits.MaxRequestBodySize = 1024 * 1024;
            options.Limits.MaxConcurrentConnections = 16;
            options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);
            options.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(30);
            options.ListenAnyIP(listenPort, listen => { listen.Protocols = HttpProtocols.Http1; listen.UseHttps(certificate); });
        });
        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            var remote = context.Connection.RemoteIpAddress;
            if (remote == null || !(IsLocalAddress(remote) || (_allowLoopback && IPAddress.IsLoopback(remote))))
            { context.Response.StatusCode = 403; return; }
            if (context.Request.Path != "/v1/pair" || !HttpMethods.IsPost(context.Request.Method))
            {
                string auth = context.Request.Headers.Authorization.ToString();
                lock (_gate)
                {
                    if (_peer == null || !auth.StartsWith("Bearer ", StringComparison.Ordinal) || auth.Length != 71 ||
                        !SecretEquals(Hash(auth[7..]), _peer.CredentialHash))
                    { context.Response.StatusCode = 401; return; }
                    context.Items["peer"] = _peer;
                    _lastSeen = DateTime.UtcNow;
                }
                NotifyState();
            }
            try { await next(context); }
            catch (Exception error) when (error is InvalidDataException or JsonException or ArgumentException or FormatException)
            {
                if (!context.Response.HasStarted) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "同步数据格式或版本不匹配，请重新同步。" }); }
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
            catch (Microsoft.Data.Sqlite.SqliteException)
            { if (!context.Response.HasStarted) context.Response.StatusCode = 503; }
        });
        app.MapPost("/v1/pair", (Func<HttpContext, Task<IResult>>)PairAsync);
        app.MapGet("/v1/hello", (HttpContext context) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                return Results.Json(new { version = 1, serverId = ServerId, clientId = _peer!.DeviceId,
                    serverSeq = _database.GetLocalSyncSequence(), receivedClientSeq = _database.GetReceivedSyncSequence(_peer!.DeviceId).ToString() });
            }
        });
        app.MapPost("/v1/push", async (HttpContext context) =>
        {
            var request = await context.Request.ReadFromJsonAsync<PushRequest>(SyncProtocol.Json, context.RequestAborted);
            if (request?.Changes == null) throw new InvalidDataException();
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                long received = _database.ApplySyncChanges(_peer!.DeviceId, request.Changes);
                return Results.Json(new { receivedClientSeq = received.ToString() });
            }
        });
        app.MapGet("/v1/changes", (HttpContext context, string after) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                long cursor = SyncProtocol.Number(after);
                string seq = _database.GetLocalSyncSequence();
                var changes = _database.GetSyncChanges(ServerId, cursor);
                bool snapshotRequired = cursor < SyncProtocol.Number(seq) &&
                    (changes.Count == 0 || SyncProtocol.Number(changes[0].Seq) != cursor + 1);
                return Results.Json(new { changes, serverSeq = seq, snapshotRequired }, SyncProtocol.Json);
            }
        });
        app.MapPost("/v1/client-snapshot", async (HttpContext context) =>
        {
            var request = await context.Request.ReadFromJsonAsync<UploadStart>(SyncProtocol.Json, context.RequestAborted);
            if (request == null) return Results.BadRequest();
            SyncProtocol.Number(request.Seq);
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                _upload = new UploadLease(Secret(), _peer!, request.Seq);
                return Results.Json(new { id = _upload.Id });
            }
        });
        app.MapPost("/v1/client-snapshot/{id}", async (HttpContext context, string id, int page, bool complete) =>
        {
            var request = await context.Request.ReadFromJsonAsync<SyncSnapshotPage>(SyncProtocol.Json, context.RequestAborted);
            if (request?.Records == null || request.Records.Count > 128) return Results.BadRequest();
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (_upload == null || _upload.Id != id || _upload.Peer != _peer ||
                    _upload.Expires < DateTime.UtcNow || _upload.Page != page) return Results.Conflict();
                var upload = _upload;
                upload.Bytes += Encoding.UTF8.GetByteCount(SyncProtocol.Encode(request));
                if (upload.Records.Count + request.Records.Count > 50000 || upload.Bytes > 32 * 1024 * 1024)
                { _upload = null; return Results.StatusCode(413); }
                upload.Records.AddRange(request.Records); upload.Page++;
                if (!complete) return Results.Ok();
                _upload = null;
                long received = _database.ApplyClientSnapshot(_peer!.DeviceId, upload.Seq, upload.Records);
                return Results.Json(new { receivedClientSeq = received.ToString() });
            }
        });
        app.MapPost("/v1/snapshot", (HttpContext context) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                foreach (string key in _snapshots.Where(s => s.Value.Expires < DateTime.UtcNow).Select(s => s.Key).ToList()) _snapshots.Remove(key);
                var (seq, records) = _database.GetSyncSnapshot();
                if (records.Count > 50000 || Encoding.UTF8.GetByteCount(SyncProtocol.Encode(records)) > 32 * 1024 * 1024)
                    return Results.Problem("元数据数量超过本次快照安全上限。", statusCode: 413);
                _snapshots.Clear();
                string id = Secret();
                _snapshots[id] = new(_peer!.DeviceId, _peer.CredentialHash, DateTime.UtcNow.AddMinutes(5), seq, records);
                return Results.Json(new SyncSnapshot(id, seq, Math.Max(1, (records.Count + 127) / 128)), SyncProtocol.Json);
            }
        });
        app.MapGet("/v1/snapshot/{id}", (HttpContext context, string id, int page) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (!_snapshots.TryGetValue(id, out var snapshot) || snapshot.Expires < DateTime.UtcNow ||
                    snapshot.DeviceId != _peer!.DeviceId || snapshot.CredentialHash != _peer.CredentialHash ||
                    page < 0 || page >= Math.Max(1, (snapshot.Records.Count + 127) / 128)) return Results.NotFound();
                return Results.Json(new SyncSnapshotPage(snapshot.Records.Skip(page * 128).Take(128).ToList()), SyncProtocol.Json);
            }
        });
        app.MapPost("/v1/complete", async (HttpContext context) =>
        {
            var request = await context.Request.ReadFromJsonAsync<CompleteRequest>(SyncProtocol.Json, context.RequestAborted)
                ?? new CompleteRequest(false);
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (request.Record) _database.AddSyncLog(true, "同步完成：收藏、最近阅读和阅读进度已对账。");
            }
            NotifyState(); return Results.Ok();
        });
        app.MapPost("/v1/disconnect", (HttpContext context) =>
        {
            lock (_gate) { if (!StillAuthorized(context)) return Results.Unauthorized(); _lastSeen = default; }
            NotifyState(); return Results.Ok();
        });
        app.MapDelete("/v1/pair", (HttpContext context) =>
        {
            lock (_gate) { if (!StillAuthorized(context)) return Results.Unauthorized(); ForgetPeer(); }
            return Results.Ok();
        });
        return app;
    }

    private bool StillAuthorized(HttpContext context) => ReferenceEquals(context.Items["peer"], _peer) && _peer != null;

    private async Task<IResult> PairAsync(HttpContext context)
    {
        var request = await context.Request.ReadFromJsonAsync<PairRequest>(SyncProtocol.Json, context.RequestAborted);
        if (request == null || request.Token == null || request.Token.Length != 64 ||
            !Guid.TryParseExact(request.DeviceId, "N", out _) || request.DeviceId == ServerId ||
            string.IsNullOrWhiteSpace(request.Name) || request.Name.Length > 128 || request.Name.Any(char.IsControl))
            return Results.BadRequest();
        string reservation;
        lock (_gate)
        {
            // A response can be lost after committing the binding. Permit the same
            // short-lived request to recover its credential without pairing twice.
            if (_peer?.DeviceId == request.DeviceId && _receiptDevice == request.DeviceId &&
                _receiptToken != null && DateTime.UtcNow < _receiptExpires && SecretEquals(request.Token, _receiptToken))
                return Results.Json(new { version = 1, serverId = ServerId, credential = _receiptCredential });
            if (DateTime.UtcNow >= _receiptExpires) _receiptDevice = _receiptToken = _receiptCredential = null;
            if (_peer != null || _pairBusy) return Results.Conflict(new { error = "当前设备已绑定，请先解除配对。" });
            if (_pairToken == null || DateTime.UtcNow >= _pairExpires || _failedPairAttempts >= 5 ||
                !SecretEquals(request.Token, _pairToken))
            { _failedPairAttempts++; return Results.Unauthorized(); }
            _pairBusy = true; reservation = _pairToken;
        }
        try
        {
            bool accepted = ConfirmPairingAsync != null && await ConfirmPairingAsync(request.Name).WaitAsync(TimeSpan.FromSeconds(60), context.RequestAborted);
            lock (_gate)
            {
                if (!accepted || _peer != null || _pairToken != reservation || DateTime.UtcNow >= _pairExpires)
                    return Results.Conflict(new { error = "配对已取消或二维码已过期，请重新扫码。" });
                string credential = Secret();
                var peer = new PairedDevice(request.DeviceId, request.Name.Trim(), Hash(credential));
                SaveProtected("peer.dpapi", Encoding.UTF8.GetBytes(SyncProtocol.Encode(peer)));
                _receiptDevice = request.DeviceId; _receiptToken = reservation;
                _receiptCredential = credential; _receiptExpires = _pairExpires;
                _peer = peer; _pairToken = null; _lastSeen = DateTime.UtcNow;
                _database.AddSyncLog(true, "设备配对成功。");
                NotifyState();
                return Results.Json(new { version = 1, serverId = ServerId, credential });
            }
        }
        catch (TimeoutException) { return Results.StatusCode(408); }
        finally { lock (_gate) _pairBusy = false; }
    }

    public async Task<PairOffer> CreatePairOfferAsync()
    {
        await StartAsync().ConfigureAwait(false);
        var endpoints = Endpoints;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_peer != null) throw new InvalidOperationException("已配对一台设备，请先解除当前配对。");
            _pairToken = Secret(); _pairExpires = DateTime.UtcNow.AddMinutes(2); _failedPairAttempts = 0;
            _receiptDevice = _receiptToken = _receiptCredential = null;
            return new("sorryread-pair", 1, ServerId, Environment.MachineName, endpoints,
                CertificateSha256, _pairToken, _pairExpires.ToString("O"));
        }
    }
    public void ClosePairing() { lock (_gate) _pairToken = null; }
    public void ForgetPeer()
    {
        lock (_gate)
        {
            string path = Path.Combine(_directory, "peer.dpapi");
            if (File.Exists(path)) File.Delete(path);
            _peer = null; _pairToken = null; _lastSeen = default; _snapshots.Clear(); _upload = null;
            _receiptDevice = _receiptToken = _receiptCredential = null;
        }
        _database.AddSyncLog(true, "已解除设备配对，阅读数据保留。"); NotifyState();
    }

    private void StartAdvertisement()
    {
        try
        {
            _multicast = new MulticastService();
            _discovery = new ServiceDiscovery(_multicast);
            _multicast.Start();
            RefreshAdvertisement();
            NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        }
        catch (Exception) { Error = "自动发现暂不可用，仍可使用二维码中的局域网地址连接。"; }
    }
    private void OnNetworkChanged(object? sender, EventArgs e) => RefreshAdvertisement();
    private void RefreshAdvertisement()
    {
        lock (_gate)
        {
            if (_discovery == null || _disposed) return;
            try
            {
                if (_profile != null) _discovery.Unadvertise(_profile);
                _profile = new ServiceProfile("sorryread-" + ServerId[..12], "_sorryread._tcp", (ushort)Port, LocalAddresses());
                _profile.AddProperty("id", ServerId); _profile.AddProperty("v", "1");
                // Native mDNS resolvers can return only one NIC address. Include the same
                // bounded LAN addresses as the QR code so Wi-Fi remains reachable on multi-NIC PCs.
                _profile.AddProperty("a", string.Join(",", PairingAddresses()));
                _discovery.Advertise(_profile); _discovery.Announce(_profile);
            }
            catch (Exception) { Error = "网络发生变化，自动发现暂未恢复。"; }
        }
        NotifyState();
    }
    private void NotifyState() => StateChanged?.Invoke(this, EventArgs.Empty);

    public ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            _disposed = true;
            _pairToken = null;
            // Application.Exit synchronously waits for this task. It must neither
            // capture the dispatcher nor race an in-flight server initialization.
            _disposeTask ??= Task.Run(DisposeCoreAsync);
            return new ValueTask(_disposeTask);
        }
    }

    private async Task DisposeCoreAsync()
    {
        await _startGate.WaitAsync().ConfigureAwait(false);
        try
        {
            NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
            _statusTimer?.Dispose();
            try { if (_profile != null) _discovery?.Unadvertise(_profile); } catch { /* Continue shutdown if the network is gone. */ }
            try { _discovery?.Dispose(); } catch { /* Still stop HTTPS if discovery cleanup fails. */ }
            try { _multicast?.Dispose(); } catch { /* Still release the listener and certificate. */ }
            try
            {
                if (_host != null)
                {
                    try { await _host.StopAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
                    finally { await _host.DisposeAsync().ConfigureAwait(false); }
                }
            }
            finally
            {
                _host = null;
                _certificate?.Dispose();
            }
        }
        finally { _startGate.Release(); }
    }
}
