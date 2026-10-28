using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TRNRun;

/// <summary>A client for one running trnrund process, with one async method per trnrund command.</summary>
/// <remarks>
/// <para>
/// Each request is one JSON line written to trnrund's stdin, answered by one JSON line on its stdout.
/// The class is thread-safe: concurrent requests are queued and sent one at a time, so replies never get mixed up.
/// </para>
/// <para>
/// A <see cref="CancellationToken"/> only cancels the wait for the requests ahead in the queue. Once a request is
/// sent it always runs to its reply, because abandoning it would leave its reply to be read by the next request.
/// </para>
/// <para>
/// Disposing waits for the request in progress, then closes trnrund's stdin, which makes trnrund kill every
/// unfinished simulation and exit. Later requests, and requests still queued, throw <see cref="ObjectDisposedException"/>.
/// </para>
/// </remarks>
public sealed class TRNRunDaemon : IDisposable, IAsyncDisposable
{
    /// <summary>How long disposal waits for the request in progress, and then for trnrund to exit, before killing it.</summary>
    private static readonly TimeSpan CloseWait = TimeSpan.FromSeconds(10);

    /// <summary>Directory of the bundled trnrund.exe and trnrun.exe, which the package copies beside the application.</summary>
    private static readonly string NativeDirectory = Path.Combine(AppContext.BaseDirectory, "native");

    private readonly Process _process;
    private readonly Task<string> _stderr;
    private readonly SemaphoreSlim _turn = new(1, 1); // Held by the one request that owns the pipe.
    private int _disposed; // 1 once disposal starts; an int so Interlocked can set it.

    /// <summary>Wraps a started trnrund and drains its stderr in the background, so trnrund never blocks on a full pipe.</summary>
    private TRNRunDaemon(Process process)
    {
        _process = process;
        _stderr = process.StandardError.ReadToEndAsync();
    }

    /// <summary>Starts trnrund and waits until it answers its first request.</summary>
    /// <param name="workers">How many simulations run at once; <see langword="null"/> keeps trnrund's default, the CPU count minus one.</param>
    /// <param name="trnrundPath">trnrund executable to start; <see langword="null"/> uses the bundled one.</param>
    /// <param name="trnrunPath">TRNRun executable that trnrund launches once per simulation; <see langword="null"/> uses the bundled one.</param>
    /// <param name="cancellationToken">Stops waiting for trnrund to answer; the half-started trnrund is then shut down.</param>
    /// <returns>A daemon ready for requests; dispose it to stop trnrund.</returns>
    /// <exception cref="FileNotFoundException"><paramref name="trnrundPath"/> does not exist.</exception>
    /// <exception cref="DaemonExitedException">trnrund exited before answering, such as for an invalid <paramref name="workers"/> or a missing <paramref name="trnrunPath"/>.</exception>
    /// <exception cref="TRNRunException">trnrund answered with something other than its JSON protocol.</exception>
    public static async Task<TRNRunDaemon> StartAsync(
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

        var daemon = new TRNRunDaemon(Process.Start(startInfo)!);
        try
        {
            // WaitAsync lets the token abandon even the sent request; safe only because the daemon is disposed right after.
            await daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" }).WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            await daemon.DisposeAsync().ConfigureAwait(false);
            throw;
        }

        return daemon;
    }

    /// <summary>Sends one raw request and returns its reply; the escape hatch for anything the typed methods don't cover.</summary>
    /// <param name="request">Request object, such as <c>{"cmd": "ready"}</c>; trnrund's README lists the commands.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    /// <returns>trnrund's reply, whose <c>ok</c> is always <see langword="true"/>.</returns>
    /// <exception cref="RequestException">trnrund refused the request.</exception>
    /// <exception cref="DaemonExitedException">trnrund stopped answering.</exception>
    /// <exception cref="TRNRunException">trnrund answered with something other than its JSON protocol.</exception>
    /// <exception cref="ObjectDisposedException">The daemon is disposed.</exception>
    public async Task<JsonObject> RequestAsync(JsonObject request, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) == 1, this);
        await _turn.WaitAsync(cancellationToken).ConfigureAwait(false);
        string line;
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) == 1, this); // Checked again: disposal may have started while this request was queued.
            line = await ExchangeAsync(request.ToJsonString()).ConfigureAwait(false)
                ?? throw new DaemonExitedException(await ExitMessageAsync().ConfigureAwait(false));
        }
        finally
        {
            _turn.Release();
        }

        JsonObject response;
        bool? ok;
        try
        {
            response = JsonNode.Parse(line) as JsonObject ?? throw new JsonException("not an object");
            ok = response["ok"]?.GetValue<bool>();
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            throw new TRNRunException($"trnrund replied outside its protocol: {line}", error);
        }

        if (ok != true)
        {
            throw new RequestException(response["error"] is JsonValue error && error.TryGetValue(out string? message) ? message : line);
        }

        return response;
    }

    /// <summary>Queues a deck to run; it starts once a worker is free.</summary>
    /// <param name="deckFile">Deck to run; a relative path resolves from the current directory.</param>
    /// <param name="settings">TRNRun options; <see langword="null"/> keeps every TRNRun default.</param>
    /// <param name="label">Free text stored with the simulation, such as a name to display; trnrund does not use it.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    /// <returns>The new simulation's simId, used by every other method.</returns>
    /// <exception cref="RequestException">trnrund refused the deck, such as a missing file.</exception>
    /// <exception cref="FileNotFoundException"><see cref="SimulationSettings.TrnexePath"/> does not exist.</exception>
    public async Task<long> AddAsync(
        string deckFile,
        SimulationSettings? settings = null,
        string? label = null,
        CancellationToken cancellationToken = default)
    {
        var request = new JsonObject
        {
            ["cmd"] = "add",
            ["deckFile"] = Path.GetFullPath(deckFile),
            ["trnrunOptions"] = settings?.ToTrnrunOptions() ?? new JsonObject(),
        };
        if (label is not null)
        {
            request["label"] = label;
        }

        JsonObject response = await RequestAsync(request, cancellationToken).ConfigureAwait(false);
        return Read(response, "simId", node => node.GetValue<long>());
    }

    /// <summary>Returns the current snapshot of one simulation.</summary>
    /// <param name="simId">Simulation returned by <see cref="AddAsync"/>.</param>
    /// <param name="withLogs">Whether to include <see cref="Simulation.Logs"/>; left empty otherwise, since logs can be large.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or was released.</exception>
    public async Task<Simulation> GetSimulationAsync(long simId, bool withLogs = false, CancellationToken cancellationToken = default)
    {
        var request = new JsonObject { ["cmd"] = "simulation", ["simId"] = simId, ["withLogs"] = withLogs };
        JsonObject response = await RequestAsync(request, cancellationToken).ConfigureAwait(false);
        return Read(response, "simulation", node => node.Deserialize(TRNRunJsonContext.Default.Simulation));
    }

    /// <summary>Returns the current snapshot of every unreleased simulation in one state, oldest first.</summary>
    /// <param name="state">State to list.</param>
    /// <param name="withLogs">Whether to include each <see cref="Simulation.Logs"/>; left empty otherwise, since logs can be large.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    public async Task<IReadOnlyList<Simulation>> GetSimulationsAsync(
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
        return Read(response, "simulations", node => node.Deserialize(TRNRunJsonContext.Default.SimulationArray));
    }

    /// <summary>Polls a simulation until it is <see cref="SimulationState.Finished"/>.</summary>
    /// <param name="simId">Simulation to wait for.</param>
    /// <param name="pollInterval">Delay between polls; <see langword="null"/> for half a second.</param>
    /// <param name="cancellationToken">Stops waiting; the simulation itself keeps running.</param>
    /// <returns>The finished simulation, without its logs; call <see cref="GetSimulationAsync"/> with <c>withLogs</c> for them.</returns>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or was released.</exception>
    public async Task<Simulation> WaitForFinishedAsync(long simId, TimeSpan? pollInterval = null, CancellationToken cancellationToken = default)
    {
        TimeSpan interval = pollInterval ?? TimeSpan.FromMilliseconds(500);
        while (true)
        {
            Simulation sim = await GetSimulationAsync(simId, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (sim.State == SimulationState.Finished)
            {
                return sim;
            }

            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Stops a queued or running simulation; it then finishes with <see cref="SimulationStatus.Cancelled"/>. One already finished is left unchanged.</summary>
    /// <param name="simId">Simulation to cancel.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or was released.</exception>
    public async Task CancelAsync(long simId, CancellationToken cancellationToken = default) =>
        await RequestAsync(new JsonObject { ["cmd"] = "cancel", ["simId"] = simId }, cancellationToken).ConfigureAwait(false);

    /// <summary>Makes trnrund forget a finished simulation and its logs, freeing their memory; its simId is then unknown.</summary>
    /// <param name="simId">Simulation to release.</param>
    /// <param name="cancellationToken">Cancels the wait for earlier requests; see the class remarks.</param>
    /// <exception cref="RequestException"><paramref name="simId"/> is unknown or not finished.</exception>
    public async Task ReleaseAsync(long simId, CancellationToken cancellationToken = default) =>
        await RequestAsync(new JsonObject { ["cmd"] = "release", ["simId"] = simId }, cancellationToken).ConfigureAwait(false);

    /// <summary>Blocking version of <see cref="DisposeAsync"/>, which can take seconds; prefer <c>await using</c> on a UI thread.</summary>
    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult(); // Every await inside uses ConfigureAwait(false), so this cannot deadlock.

    /// <summary>Stops trnrund, interrupting every unfinished simulation; calling it again does nothing.</summary>
    /// <remarks>
    /// Waits for the request in progress, then closes trnrund's stdin so it kills its runs and exits.
    /// If either wait takes longer than 10 seconds, trnrund and its child processes are killed instead.
    /// </remarks>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1)
        {
            return;
        }

        if (await _turn.WaitAsync(CloseWait).ConfigureAwait(false))
        {
            try
            {
                _process.StandardInput.Close();
            }
            catch (IOException)
            {
                // trnrund already exited.
            }

            using var timeout = new CancellationTokenSource(CloseWait);
            try
            {
                await _process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                await KillAsync().ConfigureAwait(false);
            }
        }
        else
        {
            await KillAsync().ConfigureAwait(false); // Its stdout then ends, so the request in progress gives up the turn.
            await _turn.WaitAsync().ConfigureAwait(false);
        }

        _process.Dispose();
        _turn.Release(); // Requests waiting for their turn now see they are disposed.
    }

    /// <summary>Kills trnrund and its children, so a hung trnrund does not leave TRNRun and TRNSYS running.</summary>
    private async Task KillAsync()
    {
        _process.Kill(entireProcessTree: true);
        await _process.WaitForExitAsync().ConfigureAwait(false);
    }

    /// <summary>Reads one field of an accepted reply, throwing <see cref="TRNRunException"/> if it is missing or malformed.</summary>
    private static T Read<T>(JsonObject response, string key, Func<JsonNode, T?> read)
    {
        Exception? cause = null;
        try
        {
            if (response[key] is { } node && read(node) is { } value)
            {
                return value;
            }
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            cause = error;
        }

        throw new TRNRunException($"trnrund replied outside its protocol: {response.ToJsonString()}", cause);
    }

    /// <summary>Writes one request line and returns the reply line; <see langword="null"/> once trnrund is gone.</summary>
    private async Task<string?> ExchangeAsync(string requestLine)
    {
        try
        {
            await _process.StandardInput.WriteLineAsync(requestLine).ConfigureAwait(false);
            await _process.StandardInput.FlushAsync().ConfigureAwait(false);
            return await _process.StandardOutput.ReadLineAsync().ConfigureAwait(false);
        }
        catch (IOException)
        {
            return null; // Broken pipe.
        }
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
