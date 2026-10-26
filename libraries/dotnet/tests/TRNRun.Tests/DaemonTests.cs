using System.Diagnostics;
using System.Text.Json.Nodes;

namespace TRNRun.Tests;

/// <summary>TRNRunDaemon against the real trnrund.exe, with TRNRun.FakeTrnrun as the runner.</summary>
public sealed class DaemonTests : IDisposable
{
    private readonly Decks _decks = new();

    /// <summary>Deletes the test's decks.</summary>
    public void Dispose() => _decks.Dispose();

    /// <summary>Starts trnrund with the fake runner.</summary>
    private static Task<TRNRunDaemon> StartAsync(int? workers = null) => TRNRunDaemon.StartAsync(workers, trnrunPath: Decks.FakeTrnrun);

    /// <summary>Polls a simulation until it is in <paramref name="state"/>; fails after 10 s.</summary>
    private static async Task<Simulation> WaitUntilAsync(TRNRunDaemon daemon, long simId, SimulationState state)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            Simulation sim = await daemon.GetSimulationAsync(simId);
            if (sim.State == state)
            {
                return sim;
            }

            Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"simulation {simId} still {sim.State}");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task RunsADeckToTheEnd()
    {
        using TRNRunDaemon daemon = await StartAsync(workers: 1);
        long simId = await daemon.AddAsync(_decks.Write(), label: "one");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        Assert.Equal(SimulationState.Finished, (await daemon.WaitForFinishedAsync(simId, TimeSpan.FromMilliseconds(10), timeout.Token)).State);

        Simulation sim = Assert.Single(await daemon.GetSimulationsAsync(SimulationState.Finished, withLogs: true));
        Assert.Equal((simId, "one", true, 0, 1), (sim.SimId, sim.Label, sim.Succeeded, sim.ExitCode, sim.Warnings));
        Assert.Equal(SimulationStatus.Done, sim.Status);
        Assert.Equal((0, 10, 1), (sim.StartTime, sim.StopTime, sim.TimeStep));
        Assert.Equal((10, 1, TimeSpan.FromMilliseconds(5), TimeSpan.Zero), (sim.SimTime, sim.Percent, sim.Elapsed, sim.Eta));
        LogEvent log = Assert.Single(sim.Logs);
        Assert.Equal(new LogEvent { Severity = LogSeverity.Warning, Time = 5, UnitId = 7, TypeId = 56, Message = "careful" }, log);
        Assert.True(sim.SubmittedAt <= sim.StartedAt && sim.StartedAt <= sim.FinishedAt);
        Assert.Equal(TimeSpan.Zero, sim.FinishedAt!.Value.Offset);

        Assert.Empty(Assert.Single(await daemon.GetSimulationsAsync(SimulationState.Finished)).Logs);
        Assert.Single((await daemon.GetSimulationAsync(simId, withLogs: true)).Logs);
        Assert.Empty((await daemon.GetSimulationAsync(simId)).Logs);
        await daemon.ReleaseAsync(simId);
        Assert.Empty(await daemon.GetSimulationsAsync(SimulationState.Finished));
    }

    [Fact]
    public async Task ProgressIsNullUntilReported()
    {
        using TRNRunDaemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(events: []));
        Simulation sim = await WaitUntilAsync(daemon, simId, SimulationState.Finished);
        Assert.Equal((null, null, null), (sim.Percent, sim.Elapsed, sim.Eta));
    }

    [Fact]
    public async Task WaitForFinishedCanBeCancelled()
    {
        using TRNRunDaemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(gated: true));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => daemon.WaitForFinishedAsync(simId, TimeSpan.FromMilliseconds(10), timeout.Token));
    }

    [Fact]
    public async Task AddMakesTheDeckAbsoluteAndOmitsNoLabel()
    {
        string deck = _decks.Write();
        string relative = Path.GetRelativePath(Environment.CurrentDirectory, deck);
        using TRNRunDaemon daemon = await StartAsync();
        Simulation sim = await daemon.GetSimulationAsync(await daemon.AddAsync(relative));
        Assert.Equal((deck, null), (sim.DeckFile, sim.Label));
    }

    [Fact]
    public async Task AddPassesSettingsAsTrnrunArgs()
    {
        using TRNRunDaemon daemon = await StartAsync();
        var settings = new SimulationSettings { WatchTmp = true, Severity = LogSeverity.Fatal, GuiVisibility = GuiVisibility.MinimizedAuto };
        Simulation sim = await daemon.GetSimulationAsync(await daemon.AddAsync(_decks.Write(), settings));
        Assert.Equal(["--guiVisibility:minauto", "--watchTmp:true", "--severity:Fatal"], sim.TrnrunArgs);
    }

    [Fact]
    public async Task AddRefusesABadSetting()
    {
        using TRNRunDaemon daemon = await StartAsync();
        var error = await Assert.ThrowsAsync<RequestException>(
            () => daemon.AddAsync(_decks.Write(), new SimulationSettings { Severity = (LogSeverity)99 }));
        Assert.Contains("severity", error.Message);
        Assert.Empty(await daemon.GetSimulationsAsync(SimulationState.Queued));
    }

    [Fact]
    public async Task AFailedRunnerIsReported()
    {
        using TRNRunDaemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(events: [], exitCode: 3));
        Simulation sim = await WaitUntilAsync(daemon, simId, SimulationState.Finished);
        Assert.Equal((SimulationStatus.Error, 3, false), (sim.Status, sim.ExitCode, sim.Succeeded));
    }

    [Fact]
    public async Task CancelStopsQueuedAndRunning()
    {
        using TRNRunDaemon daemon = await StartAsync(workers: 1);
        long running = await daemon.AddAsync(_decks.Write(gated: true));
        long queued = await daemon.AddAsync(_decks.Write());
        await WaitUntilAsync(daemon, running, SimulationState.Running);
        await daemon.CancelAsync(queued);
        await daemon.CancelAsync(running);
        foreach (long simId in new[] { running, queued })
        {
            Simulation sim = await WaitUntilAsync(daemon, simId, SimulationState.Finished);
            Assert.Equal((SimulationStatus.Cancelled, false, null), (sim.Status, sim.Succeeded, sim.ExitCode));
            Assert.Contains("cancelled", sim.Error);
        }

        Assert.Null((await daemon.GetSimulationAsync(queued)).StartedAt);
    }

    [Fact]
    public async Task CancelAndReleaseRefuseTheWrongState()
    {
        using TRNRunDaemon daemon = await StartAsync(workers: 1);
        long simId = await daemon.AddAsync(_decks.Write(gated: true));
        await Assert.ThrowsAsync<RequestException>(() => daemon.ReleaseAsync(simId));
        await daemon.CancelAsync(simId);
        await WaitUntilAsync(daemon, simId, SimulationState.Finished);
        await daemon.CancelAsync(simId); // A finished run is left unchanged, not refused.
        await daemon.ReleaseAsync(simId);
        foreach (Func<Task> request in new Func<Task>[] { () => daemon.CancelAsync(simId), () => daemon.ReleaseAsync(simId), () => daemon.GetSimulationAsync(simId) })
        {
            Assert.Contains("Unknown simId", (await Assert.ThrowsAsync<RequestException>(request)).Message);
        }
    }

    [Fact]
    public async Task RequestSendsARawRequest()
    {
        using TRNRunDaemon daemon = await StartAsync();
        Assert.Equal("""{"ok":true}""", (await daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" })).ToJsonString());
        await Assert.ThrowsAsync<RequestException>(() => daemon.RequestAsync(new JsonObject { ["cmd"] = "nope" }));
    }

    [Fact]
    public async Task AReplyOutsideTheProtocolThrowsTRNRunException()
    {
        // A batch file stands in for trnrund: it reads the ready request and answers with a line that is not JSON.
        string fake = Path.Combine(_decks.Directory, "garbage.cmd");
        File.WriteAllText(fake, "@set /p request=\r\n@echo not json\r\n");
        var error = await Assert.ThrowsAsync<TRNRunException>(() => TRNRunDaemon.StartAsync(trnrundPath: fake, trnrunPath: Decks.FakeTrnrun));
        Assert.Contains("not json", error.Message);
        Assert.NotNull(error.InnerException);
    }

    [Fact]
    public async Task AReplyMissingAFieldThrowsTRNRunException()
    {
        // A batch file stands in for trnrund: it accepts the ready and add requests, but its add reply has no simId.
        string fake = Path.Combine(_decks.Directory, "nosimid.cmd");
        File.WriteAllText(fake, "@set /p request=\r\n@echo {\"ok\":true}\r\n@set /p request=\r\n@echo {\"ok\":true}\r\n");
        await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(trnrundPath: fake, trnrunPath: Decks.FakeTrnrun);
        var error = await Assert.ThrowsAsync<TRNRunException>(() => daemon.AddAsync(_decks.Write()));
        Assert.Contains("outside its protocol", error.Message);
    }

    [Fact]
    public async Task AQueuedRequestCanBeCancelledAndADyingTrnrundIsReported()
    {
        // A batch file stands in for trnrund: it answers the ready request, reads one more, then exits about a second later without answering.
        string fake = Path.Combine(_decks.Directory, "dies.cmd");
        File.WriteAllText(fake, "@set /p request=\r\n@echo {\"ok\":true}\r\n@set /p request=\r\n@ping -n 2 127.0.0.1 >nul\r\n");
        await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(trnrundPath: fake, trnrunPath: Decks.FakeTrnrun);
        Task<JsonObject> sent = daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" });
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" }, timeout.Token));
        Assert.Contains("exited with code", (await Assert.ThrowsAsync<DaemonExitedException>(() => sent)).Message);
    }

    [Fact]
    public async Task RequestsFromThreadsTakeTurns()
    {
        using TRNRunDaemon daemon = await StartAsync();
        long[] simIds = [await daemon.AddAsync(_decks.Write()), await daemon.AddAsync(_decks.Write()), await daemon.AddAsync(_decks.Write())];
        long[] expected = [.. Enumerable.Repeat(simIds, 50).SelectMany(ids => ids)];
        Simulation[] sims = await Task.WhenAll(expected.Select(simId => Task.Run(() => daemon.GetSimulationAsync(simId))));
        Assert.Equal(expected, sims.Select(sim => sim.SimId));
    }

    [Fact]
    public async Task ARefusedRequestAndADisposedDaemonThrow()
    {
        TRNRunDaemon daemon = await StartAsync();
        Assert.Contains("not found", (await Assert.ThrowsAsync<RequestException>(() => daemon.AddAsync(Path.Combine(_decks.Directory, "missing.dck")))).Message);
        daemon.Dispose();
        daemon.Dispose();
        await daemon.DisposeAsync();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => daemon.GetSimulationAsync(1));
    }

    [Fact]
    public async Task DisposingDuringRequestsLetsEachFinishOrThrowObjectDisposed()
    {
        TRNRunDaemon daemon = await StartAsync();
        Task[] requests = [.. Enumerable.Range(0, 100).Select(_ => Task.Run(() => daemon.GetSimulationsAsync(SimulationState.Queued)))];
        await daemon.DisposeAsync();
        foreach (Task request in requests)
        {
            try
            {
                await request;
            }
            catch (ObjectDisposedException)
            {
            }
        }
    }

    [Fact]
    public async Task StartupFailuresSayWhy()
    {
        await Assert.ThrowsAsync<FileNotFoundException>(() => TRNRunDaemon.StartAsync(trnrundPath: Path.Combine(_decks.Directory, "missing.exe")));
        var missingRunner = await Assert.ThrowsAsync<DaemonExitedException>(() => TRNRunDaemon.StartAsync(trnrunPath: Path.Combine(_decks.Directory, "missing.exe")));
        Assert.Matches("code 2: .+", missingRunner.Message);
        Assert.Contains("code 2", (await Assert.ThrowsAsync<DaemonExitedException>(() => StartAsync(workers: 0))).Message);
    }

    [Fact]
    public async Task DisposeStopsUnfinishedRunsPromptly()
    {
        await using TRNRunDaemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(gated: true));
        await WaitUntilAsync(daemon, simId, SimulationState.Running);
        var clock = Stopwatch.StartNew();
        await daemon.DisposeAsync();
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5));
    }
}
