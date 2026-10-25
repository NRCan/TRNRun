using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TRNRun;

/// <summary>A running trnrund: one method per trnrund command, each sending one JSON request line and reading its reply line.</summary>
/// <remarks>
/// Requests are thread-safe: they take turns. Disposing closes trnrund's stdin, so it kills every unfinished
/// simulation and exits; requests then throw <see cref="ObjectDisposedException"/>. Do not dispose during a request.
/// A <see cref="CancellationToken"/> only cancels the wait for an earlier request: once sent, a request runs to its reply.
/// </remarks>
public sealed class Daemon : IDisposable
{
    /// <summary>How long trnrund gets to exit once its stdin closes, before it is killed.</summary>
    private static readonly TimeSpan CloseWait = TimeSpan.FromSeconds(10);

    /// <summary>Directory of the bundled trnrund.exe and trnrun.exe, copied beside the application by the package.</summary>
    private static readonly string NativeDirectory = Path.Combine(AppContext.BaseDirectory, "native");

    private readonly Process _process;
    private readonly Task<string> _stderr;
    private readonly SemaphoreSlim _turn = new(1, 1);
    private bool _disposed;

    /// <summary>Wraps a started trnrund, draining its stderr so it never blocks on a full pipe.</summary>
    private Daemon(Process process)
    {
        _process = process;
        _stderr = process.StandardError.ReadToEndAsync();
    }

    /// <summary>Starts trnrund and waits until it answers.</summary>
    /// <param name="workers">Simulations run at once; trnrund's default, the CPU count minus one, when <see langword="null"/>.</param>
    /// <param name="trnrundPath">trnrund executable; the bundled one by default.</param>
    /// <param name="trnrunPath">TRNRun executable trnrund launches per simulation; the bundled one by default.</param>
    /// <param name="cancellationToken">Cancels the wait; trnrund is then closed.</param>
    /// <exception cref="FileNotFoundException"><paramref name="trnrundPath"/> does not exist.</exception>
    /// <exception cref="DaemonExitedException">trnrund exited before answering, such as for an invalid option.</exception>
    public static async Task<Daemon> StartAsync(
        int? workers = null,
        string? trnrundPath = null,
        string? trnrunPath = null,
        CancellationToken cancellationToken = default)
    {
        string trnrund = Path.GetFullPath(trnrundPath ?? Path.Combine(NativeDirectory, "trnrund.exe"));
        if (!File.Exists(trnrund))
        {
            throw new FileNotFoundException($"trnrund executable not found: {trnrund}", trnrund);
        }

        var startInfo = new ProcessStartInfo(trnrund)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        startInfo.ArgumentList.Add($"--trnrun:{Path.GetFullPath(trnrunPath ?? Path.Combine(NativeDirectory, "trnrun.exe"))}");
        if (workers is { } count)
        {
            startInfo.ArgumentList.Add($"--workers:{count.ToString(CultureInfo.InvariantCulture)}");
        }

        var daemon = new Daemon(Process.Start(startInfo)!);
        try
        {
            // WaitAsync: the token must also abandon a sent request, which is safe since the daemon is then disposed.
            await daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" }).WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            daemon.Dispose();
            throw;
        }

        return daemon;
    }

    /// <summary>Sends one raw request and returns its reply, for anything the typed methods don't cover.</summary>
    /// <param name="request">Request object, such as <c>{"cmd": "ready"}</c>; see trnrund's README.</param>
    /// <param name="cancellationToken">Cancels the wait for an earlier request.</param>
    /// <returns>trnrund's reply, its <c>ok</c> true.</returns>
    /// <exception cref="RequestException">trnrund refused the request.</exception>
    /// <exception cref="DaemonExitedException">trnrund stopped answering.</exception>
    public async Task<JsonObject> RequestAsync(JsonObject request, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _turn.WaitAsync(cancellationToken).ConfigureAwait(false);
        string? line;
        try
        {
            await _process.StandardInput.WriteLineAsync(request.ToJsonString()).ConfigureAwait(false);
            await _process.StandardInput.FlushAsync().ConfigureAwait(false);
            line = await _process.StandardOutput.ReadLineAsync().ConfigureAwait(false);
        }
        catch (IOException)
        {
            line = null; // Broken pipe: trnrund is gone.
        }
        finally
        {
            _turn.Release();
        }

        if (line is null)
        {
            throw new DaemonExitedException(await ExitMessageAsync().ConfigureAwait(false));
        }

        if (JsonNode.Parse(line) is not JsonObject response)
        {
            throw new TrnrunException($"trnrund replied outside its protocol: {line}");
        }

        if (response["ok"]?.GetValue<bool>() != true)
        {
            throw new RequestException(response["error"]?.GetValue<string>() ?? line);
        }

        return response;
    }

    /// <summary>Queues a deck and returns its simId; it may not have started yet.</summary>
    /// <param name="deckFile">Deck to run; a relative path resolves from the current directory.</param>
    /// <param name="settings">TRNRun options; <see langword="null"/> keeps every TRNRun default.</param>
    /// <param name="label">Free text stored with the simulation.</param>
    /// <param name="cancellationToken">Cancels the wait for an earlier request.</param>
    /// <exception cref="RequestException">trnrund refused the deck or the settings.</exception>
    /// <exception cref="FileNotFoundException"><see cref="SimulationSettings.TrnexePath"/> does not exist.</exception>
    public async Task<long> AddAsync(
        string deckFile,
        SimulationSettings? settings = null,
        string? label = null,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<string> args = settings?.ToCliArgs() ?? [];
        var request = new JsonObject
        {
            ["cmd"] = "add",
            ["deckFile"] = Path.GetFullPath(deckFile),
            ["trnrunArgs"] = new JsonArray([.. args.Select(arg => (JsonNode)arg)]),
        };
        if (label is not null)
        {
            request["label"] = label;
        }

        JsonObject response = await RequestAsync(request, cancellationToken).ConfigureAwait(false);
        return response["simId"]!.GetValue<long>();
    }

    /// <summary>Returns one simulation; its <see cref="Simulation.Logs"/> are empty unless <paramref name="withLogs"/>.</summary>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or was released.</exception>
    public async Task<Simulation> SimulationAsync(long simId, bool withLogs = false, CancellationToken cancellationToken = default)
    {
        var request = new JsonObject { ["cmd"] = "simulation", ["simId"] = simId, ["withLogs"] = withLogs };
        JsonObject response = await RequestAsync(request, cancellationToken).ConfigureAwait(false);
        return response["simulation"].Deserialize(TrnrunJsonContext.Default.Simulation)!;
    }

    /// <summary>Returns every unreleased simulation in <paramref name="state"/>, oldest first; their logs are empty unless <paramref name="withLogs"/>.</summary>
    public async Task<IReadOnlyList<Simulation>> SimulationsAsync(
        SimulationState state,
        bool withLogs = false,
        CancellationToken cancellationToken = default)
    {
        var request = new JsonObject
        {
            ["cmd"] = "simulations",
            ["state"] = state.ToString().ToUpperInvariant(),
            ["withLogs"] = withLogs,
        };
        JsonObject response = await RequestAsync(request, cancellationToken).ConfigureAwait(false);
        return response["simulations"].Deserialize(TrnrunJsonContext.Default.SimulationArray)!;
    }

    /// <summary>Stops a queued or running simulation; it then finishes as <see cref="SimulationStatus.Cancelled"/>.</summary>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or already finished.</exception>
    public async Task CancelAsync(long simId, CancellationToken cancellationToken = default) =>
        await RequestAsync(new JsonObject { ["cmd"] = "cancel", ["simId"] = simId }, cancellationToken).ConfigureAwait(false);

    /// <summary>Forgets a finished simulation and its logs.</summary>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or not finished.</exception>
    public async Task ReleaseAsync(long simId, CancellationToken cancellationToken = default) =>
        await RequestAsync(new JsonObject { ["cmd"] = "release", ["simId"] = simId }, cancellationToken).ConfigureAwait(false);

    /// <summary>Closes stdin, so trnrund kills its runs and exits, and waits for it; kills it if it does not exit.</summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        try
        {
            _process.StandardInput.Close();
        }
        catch (IOException)
        {
            // trnrund already exited.
        }

        if (!_process.WaitForExit(CloseWait))
        {
            _process.Kill(entireProcessTree: true); // A hung trnrund must not leave TRNRun and TRNSYS running.
            _process.WaitForExit();
        }

        _process.Dispose();
    }

    /// <summary>Describes why trnrund stopped answering, once its stdout ended.</summary>
    private async Task<string> ExitMessageAsync()
    {
        using var timeout = new CancellationTokenSource(CloseWait);
        try
        {
            await _process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return "trnrund closed its output but did not exit";
        }

        string stderr = (await _stderr.ConfigureAwait(false)).Trim();
        return $"trnrund exited with code {_process.ExitCode}" + (stderr.Length > 0 ? $": {stderr}" : "");
    }
}
