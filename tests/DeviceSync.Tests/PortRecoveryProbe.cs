using System.IO;
using System.Net;
using System.Net.Sockets;
using ReadAI;
using ReadAI.Sync;

internal static class PortRecoveryProbe
{
    public static async Task RunAsync()
    {
        string root = Path.Combine(Path.GetTempPath(), "sorryread-port-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var database = new ReaderDatabase(Path.Combine(root, "synthetic.db"));
        database.Initialize();
        string identity = Path.Combine(root, "identity");
        int cached;
        await using (var first = new DeviceLinkService(database, identity, allowLoopback: true))
        {
            await first.StartAsync(); cached = first.Port;
        }
        await using (var second = new DeviceLinkService(database, identity, allowLoopback: true))
        {
            await second.StartAsync();
            if (second.Port != cached) throw new Exception("Restart changed the cached endpoint");
        }
        int replacement;
        var occupied = new TcpListener(IPAddress.IPv6Any, cached);
        occupied.Server.DualMode = true;
        occupied.Start();
        try
        {
            await using var fallback = new DeviceLinkService(database, identity, allowLoopback: true);
            await fallback.StartAsync(); replacement = fallback.Port;
            if (replacement == cached) throw new Exception("Occupied port was not replaced");
        }
        finally { occupied.Stop(); }
        await using (var next = new DeviceLinkService(database, identity, allowLoopback: true))
        {
            await next.StartAsync();
            if (next.Port != replacement) throw new Exception("Replacement port was not persisted");
        }
        File.WriteAllText(Path.Combine(identity, "port.txt"), "invalid");
        await using (var corrupt = new DeviceLinkService(database, identity, allowLoopback: true))
        {
            await corrupt.StartAsync();
            if (corrupt.Port < 1024) throw new Exception("Invalid port file prevented recovery");
        }
        Console.WriteLine("PASS cached endpoint reuse, occupied-port fallback, persisted replacement and invalid port recovery");
    }
}
