using System.Diagnostics;
using System.Text.Json.Nodes;

namespace TRNRun.Tests;

/// <summary>Daemon against the real trnrund.exe, with TRNRun.FakeTrnrun as the runner.</summary>
public sealed class DaemonTests : IDisposable
{
    private readonly Decks _decks = new();

    /// <summary>Deletes the test's decks.</summary>
    public void Dispose() => _decks.Dispose();

    /// <summary>Starts trnrund with the fake runner.</summary>
    private static Task<Daemon> StartAsync(int? workers = null) => Daemon.StartAsync(workers, trnrunPath: Decks.FakeTrnrun);

    /// <summary>Polls a simulation until it is in <paramref name="state"/>; fails after 10 s.</summary>
    private static async Task<Simulation> WaitUntilAsync(Daemon daemon, long simId, SimulationState state)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            Simulation sim = await daemon.SimulationAsync(simId);
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
        using Daemon daemon = await StartAsync(workers: 1);
        long simId = await daemon.AddAsync(_decks.Write(), label: "one");
        await WaitUntilAsync(daemon, simId, SimulationState.Finished);

        Simulation sim = Assert.Single(await daemon.SimulationsAsync(SimulationState.Finished, withLogs: true));
        Assert.Equal((simId, "one", true, 0, 1), (sim.SimId, sim.Label, sim.Succeeded, sim.ExitCode, sim.Warnings));
        Assert.Equal(SimulationStatus.Done, sim.Status);
        Assert.Equal((0, 10, 1), (sim.StartTime, sim.StopTime, sim.TimeStep));
        Assert.Equal((10, 1, 5, 0), (sim.SimTime, sim.Percent, sim.ElapsedMs, sim.EtaMs));
        LogEvent log = Assert.Single(sim.Logs);
        Assert.Equal(new LogEvent { Severity = LogSeverity.Warning, Time = 5, UnitId = 7, TypeId = 56, Message = "careful" }, log);
        Assert.True(sim.SubmittedAt <= sim.StartedAt && sim.StartedAt <= sim.FinishedAt);
        Assert.Equal(TimeSpan.Zero, sim.FinishedAt!.Value.Offset);

        Assert.Empty(Assert.Single(await daemon.SimulationsAsync(SimulationState.Finished)).Logs);
        Assert.Single((await daemon.SimulationAsync(simId, withLogs: true)).Logs);
        Assert.Empty((await daemon.SimulationAsync(simId)).Logs);
        await daemon.ReleaseAsync(simId);
        Assert.Empty(await daemon.SimulationsAsync(SimulationState.Finished));
    }

    [Fact]
    public async Task AddMakesTheDeckAbsoluteAndOmitsNoLabel()
    {
        string deck = _decks.Write();
        string relative = Path.GetRelativePath(Environment.CurrentDirectory, deck);
        using Daemon daemon = await StartAsync();
        Simulation sim = await daemon.SimulationAsync(await daemon.AddAsync(relative));
        Assert.Equal((deck, null), (sim.DeckFile, sim.Label));
    }

    [Fact]
    public async Task AddPassesSettingsAsTrnrunArgs()
    {
        using Daemon daemon = await StartAsync();
        var settings = new SimulationSettings { WatchTmp = true, Severity = LogSeverity.Fatal, GuiVisibility = GuiVisibility.MinimizedAuto };
        Simulation sim = await daemon.SimulationAsync(await daemon.AddAsync(_decks.Write(), settings));
        Assert.Equal(["--guiVisibility:minauto", "--watchTmp:true", "--severity:Fatal"], sim.TrnrunArgs);
    }

    [Fact]
    public async Task AddRefusesABadSetting()
    {
        using Daemon daemon = await StartAsync();
        var error = await Assert.ThrowsAsync<RequestException>(
            () => daemon.AddAsync(_decks.Write(), new SimulationSettings { Severity = (LogSeverity)99 }));
        Assert.Contains("severity", error.Message);
        Assert.Empty(await daemon.SimulationsAsync(SimulationState.Queued));
    }

    [Fact]
    public async Task AFailedRunnerIsReported()
    {
        using Daemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(events: [], exitCode: 3));
        Simulation sim = await WaitUntilAsync(daemon, simId, SimulationState.Finished);
        Assert.Equal((SimulationStatus.Error, 3, false), (sim.Status, sim.ExitCode, sim.Succeeded));
    }

    [Fact]
    public async Task CancelStopsQueuedAndRunning()
    {
        using Daemon daemon = await StartAsync(workers: 1);
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

        Assert.Null((await daemon.SimulationAsync(queued)).StartedAt);
    }

    [Fact]
    public async Task CancelAndReleaseRefuseTheWrongState()
    {
        using Daemon daemon = await StartAsync(workers: 1);
        long simId = await daemon.AddAsync(_decks.Write(gated: true));
        await Assert.ThrowsAsync<RequestException>(() => daemon.ReleaseAsync(simId));
        await daemon.CancelAsync(simId);
        await WaitUntilAsync(daemon, simId, SimulationState.Finished);
        await Assert.ThrowsAsync<RequestException>(() => daemon.CancelAsync(simId));
        await daemon.ReleaseAsync(simId);
        foreach (Func<Task> request in new Func<Task>[] { () => daemon.CancelAsync(simId), () => daemon.ReleaseAsync(simId), () => daemon.SimulationAsync(simId) })
        {
            Assert.Contains("Unknown simId", (await Assert.ThrowsAsync<RequestException>(request)).Message);
        }
    }

    [Fact]
    public async Task RequestSendsARawRequest()
    {
        using Daemon daemon = await StartAsync();
        Assert.Equal("""{"ok":true}""", (await daemon.RequestAsync(new JsonObject { ["cmd"] = "ready" })).ToJsonString());
        await Assert.ThrowsAsync<RequestException>(() => daemon.RequestAsync(new JsonObject { ["cmd"] = "nope" }));
    }

    [Fact]
    public async Task RequestsFromThreadsTakeTurns()
    {
        using Daemon daemon = await StartAsync();
        long[] simIds = [await daemon.AddAsync(_decks.Write()), await daemon.AddAsync(_decks.Write()), await daemon.AddAsync(_decks.Write())];
        long[] expected = [.. Enumerable.Repeat(simIds, 50).SelectMany(ids => ids)];
        Simulation[] sims = await Task.WhenAll(expected.Select(simId => Task.Run(() => daemon.SimulationAsync(simId))));
        Assert.Equal(expected, sims.Select(sim => sim.SimId));
    }

    [Fact]
    public async Task ARefusedRequestAndADisposedDaemonThrow()
    {
        Daemon daemon = await StartAsync();
        Assert.Contains("not found", (await Assert.ThrowsAsync<RequestException>(() => daemon.AddAsync(Path.Combine(_decks.Directory, "missing.dck")))).Message);
        daemon.Dispose();
        daemon.Dispose();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => daemon.SimulationAsync(1));
    }

    [Fact]
    public async Task StartupFailuresSayWhy()
    {
        await Assert.ThrowsAsync<FileNotFoundException>(() => Daemon.StartAsync(trnrundPath: Path.Combine(_decks.Directory, "missing.exe")));
        var missingRunner = await Assert.ThrowsAsync<DaemonExitedException>(() => Daemon.StartAsync(trnrunPath: Path.Combine(_decks.Directory, "missing.exe")));
        Assert.Matches("code 2: .+", missingRunner.Message);
        Assert.Contains("code 2", (await Assert.ThrowsAsync<DaemonExitedException>(() => StartAsync(workers: 0))).Message);
    }

    [Fact]
    public async Task DisposeStopsUnfinishedRunsPromptly()
    {
        Daemon daemon = await StartAsync();
        long simId = await daemon.AddAsync(_decks.Write(gated: true));
        await WaitUntilAsync(daemon, simId, SimulationState.Running);
        var clock = Stopwatch.StartNew();
        daemon.Dispose();
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5));
    }
}
