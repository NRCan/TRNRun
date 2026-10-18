using System.Text.Json;
using TRNRun.Internal;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="DaemonProcess"/>: the JSON-lines exchange with a trnrund process.</summary>
/// <remarks>They run TRNRun.FakeTrnrund in place of trnrund, which answers each request as its cmd names.</remarks>
public sealed class DaemonProcessTests : IDisposable
{
    private readonly List<DaemonProcess> _started = [];

    /// <summary>Closes every process started.</summary>
    public void Dispose()
    {
        foreach (DaemonProcess process in _started)
        {
            process.Close();
        }
    }

    /// <summary>Starts the fake trnrund with <paramref name="args"/>.</summary>
    private DaemonProcess Start(string[]? args = null, double requestTimeout = 10.0, TimeSpan? closeWait = null)
    {
        var process = new DaemonProcess(Executables.FakeTrnrund, args ?? [], TimeSpan.FromSeconds(requestTimeout), closeWait);
        _started.Add(process);
        return process;
    }

    /// <summary>Sends a <c>notify</c> request, so the fake announces <paramref name="revision"/>.</summary>
    private static void Notify(DaemonProcess process, long revision) =>
        process.Request("notify", writer => writer.WriteNumber("revision", revision));

    /// <summary>Sends an <c>exit</c> request, so the fake exits with <paramref name="code"/> after replying.</summary>
    private static void Exit(DaemonProcess process, int code = 0) =>
        process.Request("exit", writer => writer.WriteNumber("code", code));

    // -----------------------------------------------------------------
    // Starting
    // -----------------------------------------------------------------

    /// <summary>Explain how to get trnrund when its executable is missing.</summary>
    [Fact]
    public void MissingExecutableNamesIt()
    {
        using var temp = new TempDirectory();
        string missing = temp.File("trnrund.exe");

        var error = Assert.Throws<FileNotFoundException>(() => new DaemonProcess(missing, [], TimeSpan.FromSeconds(1)));

        Assert.Contains("trnrund executable not found", error.Message);
        Assert.Contains(missing, error.Message);
    }

    /// <summary>Start trnrund with the given arguments.</summary>
    [Fact]
    public void StartPassesTheArguments()
    {
        DaemonProcess process = Start(["--database:runs.sqlite3", "--maxConcurrent:2"]);

        JsonElement reply = process.Request("ready");

        Assert.Equal(
            ["--database:runs.sqlite3", "--maxConcurrent:2"],
            reply.GetProperty("args").EnumerateArray().Select(arg => arg.GetString()));
    }

    // -----------------------------------------------------------------
    // Requests
    // -----------------------------------------------------------------

    /// <summary>Number each request and return the reply that repeats its id.</summary>
    [Fact]
    public void RequestReturnsTheReplyWithIncreasingIds()
    {
        DaemonProcess process = Start();

        JsonElement first = process.Request("ready");
        JsonElement second = process.Request("ready");

        Assert.True(first.GetProperty("ok").GetBoolean());
        Assert.Equal(1, first.GetProperty("id").GetInt64());
        Assert.Equal(2, second.GetProperty("id").GetInt64());
    }

    /// <summary>Throw trnrund's error for a rejected request, and keep serving.</summary>
    [Fact]
    public void RejectedRequestThrowsRequestRejectedException()
    {
        DaemonProcess process = Start();

        Assert.Equal("Rejected on purpose", Assert.Throws<RequestRejectedException>(() => process.Request("reject")).Message);
        Assert.Equal("trnrund rejected the request", Assert.Throws<RequestRejectedException>(() => process.Request("bare_reject")).Message);
        Assert.True(process.Request("ready").GetProperty("ok").GetBoolean());
    }

    /// <summary>Throw TimeoutException, and later match replies by id so the late one is not mistaken.</summary>
    [Fact]
    public void RequestTimeoutSkipsTheLateReply()
    {
        DaemonProcess process = Start(requestTimeout: 0.2);

        var error = Assert.Throws<TimeoutException>(() => process.Request("mute"));
        Assert.Contains("'mute'", error.Message);

        JsonElement reply = process.Request("ready", timeout: TimeSpan.FromSeconds(10));
        Assert.Equal(2, reply.GetProperty("id").GetInt64());
        Assert.False(reply.TryGetProperty("late", out _));
    }

    /// <summary>Throw OperationCanceledException, and later skip the abandoned request's late reply.</summary>
    [Fact]
    public async Task CancelledRequestSkipsTheLateReply()
    {
        DaemonProcess process = Start();
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => process.RequestAsync("mute", null, null, cancel.Token));

        JsonElement reply = await process.RequestAsync("ready", null, null, CancellationToken.None);
        Assert.Equal(2, reply.GetProperty("id").GetInt64());
        Assert.False(reply.TryGetProperty("late", out _));
    }

    /// <summary>Skip non-JSON, non-object and unknown lines, then still get the reply.</summary>
    [Fact]
    public void LinesThatAreNotRepliesAreSkipped()
    {
        DaemonProcess process = Start();

        Assert.True(process.Request("noise").GetProperty("ok").GetBoolean());
    }

    /// <summary>Serialize requests, so concurrent callers never swap replies.</summary>
    [Fact]
    public void RequestsFromSeveralThreadsGetTheirOwnReplies()
    {
        DaemonProcess process = Start();
        var ids = new System.Collections.Concurrent.ConcurrentBag<long>();

        Parallel.For(0, 4, new ParallelOptions { MaxDegreeOfParallelism = 4 }, _ =>
        {
            for (int index = 0; index < 10; index++)
            {
                ids.Add(process.Request("ready").GetProperty("id").GetInt64());
            }
        });

        Assert.Equal(Enumerable.Range(1, 40).Select(id => (long)id), ids.Order());
    }

    // -----------------------------------------------------------------
    // Change notifications
    // -----------------------------------------------------------------

    /// <summary>Return true once trnrund announces a revision after the one given.</summary>
    [Fact]
    public void WaitForChangesWakesOnALaterRevision()
    {
        DaemonProcess process = Start();

        Assert.False(process.WaitForChanges(0, TimeSpan.FromMilliseconds(50)));
        Notify(process, 5);

        Assert.True(process.WaitForChanges(4, TimeSpan.FromSeconds(5)));
        Assert.False(process.WaitForChanges(5, TimeSpan.FromMilliseconds(50)));
    }

    /// <summary>Never go back to an older revision announced late.</summary>
    [Fact]
    public void WaitForChangesKeepsTheLargestRevision()
    {
        DaemonProcess process = Start();
        Notify(process, 7);
        Notify(process, 3);

        Assert.True(process.WaitForChanges(6, TimeSpan.FromMilliseconds(50)));
    }

    /// <summary>Wake a waiter blocked in another thread.</summary>
    [Fact]
    public void WaitForChangesFromAnotherThread()
    {
        DaemonProcess process = Start();
        bool? woke = null;
        var waiter = new Thread(() => woke = process.WaitForChanges(0, TimeSpan.FromSeconds(10)));
        waiter.Start();

        Notify(process, 1);

        Assert.True(waiter.Join(TimeSpan.FromSeconds(10)));
        Assert.True(woke);
    }

    /// <summary>Complete an asynchronous wait once a later revision is announced, and at once for one already announced.</summary>
    [Fact]
    public async Task WaitForChangesAsyncWakesOnALaterRevision()
    {
        DaemonProcess process = Start();
        Task waiting = process.WaitForChangesAsync(4, CancellationToken.None);
        await Task.Delay(50);
        Assert.False(waiting.IsCompleted);

        Notify(process, 5);

        await waiting.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(process.WaitForChangesAsync(4, CancellationToken.None).IsCompletedSuccessfully);
    }

    /// <summary>Stop an asynchronous wait when its token is cancelled.</summary>
    [Fact]
    public async Task WaitForChangesAsyncIsCancelled()
    {
        DaemonProcess process = Start();
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => process.WaitForChangesAsync(0, cancel.Token));
    }

    // -----------------------------------------------------------------
    // Exit
    // -----------------------------------------------------------------

    /// <summary>Throw DaemonExitedException with the exit code and stderr, for every later request and wait.</summary>
    [Fact]
    public void CrashIsReportedWithItsDiagnostics()
    {
        DaemonProcess process = Start();

        Assert.Equal("trnrund exited with code 3: boom", Assert.Throws<DaemonExitedException>(() => process.Request("crash")).Message);
        Assert.Contains("code 3", Assert.Throws<DaemonExitedException>(() => process.Request("ready")).Message);

        // Its end was recorded, so this never blocks.
        var error = Assert.Throws<DaemonExitedException>(() => process.WaitForChanges(0, TimeSpan.Zero));
        Assert.Equal((3, "boom"), (error.ExitCode, error.Diagnostics));
    }

    /// <summary>Wake an asynchronous waiter with the crash.</summary>
    [Fact]
    public async Task WaitForChangesAsyncThrowsTheCrash()
    {
        DaemonProcess process = Start();
        Task waiting = process.WaitForChangesAsync(0, CancellationToken.None);

        await Assert.ThrowsAsync<DaemonExitedException>(() => process.RequestAsync("crash", null, null, CancellationToken.None));

        var error = await Assert.ThrowsAsync<DaemonExitedException>(() => waiting.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(3, error.ExitCode);
    }

    /// <summary>Report revisions announced before a crash, and only then the crash.</summary>
    [Fact]
    public void AnnouncedRevisionsAreKeptAfterACrash()
    {
        DaemonProcess process = Start();
        Notify(process, 4);
        Assert.Throws<DaemonExitedException>(() => process.Request("crash"));

        Assert.True(process.WaitForChanges(3, TimeSpan.Zero));
        Assert.Contains("code 3", Assert.Throws<DaemonExitedException>(() => process.WaitForChanges(4, TimeSpan.Zero)).Message);
    }

    /// <summary>Throw ClosedException for a clean exit not yet waited for, as right after a shutdown request.</summary>
    [Fact]
    public void UnexpectedExitWithCode0IsAClose()
    {
        DaemonProcess process = Start();
        Exit(process);

        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => process.WaitForChanges(0, TimeSpan.FromSeconds(5))).Message);
        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => process.Request("ready")).Message);
    }

    /// <summary>Throw DaemonExitedException for a failed exit nobody waited for.</summary>
    [Fact]
    public void UnexpectedExitWithAnErrorIsACrash()
    {
        DaemonProcess process = Start();
        Exit(process, 2);

        var error = Assert.Throws<DaemonExitedException>(() => process.WaitForChanges(0, TimeSpan.FromSeconds(5)));
        Assert.Equal("trnrund exited with code 2: bye", error.Message);
    }

    /// <summary>Treat an exit after Wait() as expected, and close the process.</summary>
    [Fact]
    public void WaitReturnsOnceTrnrundExitsCleanly()
    {
        DaemonProcess process = Start();
        Exit(process);

        Assert.True(process.Wait(TimeSpan.FromSeconds(10)));
        Assert.Throws<ClosedException>(() => process.WaitForChanges(0, TimeSpan.Zero));
        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => process.Request("ready")).Message);
    }

    /// <summary>Treat an exit after WaitAsync() as expected, and close the process.</summary>
    [Fact]
    public async Task WaitAsyncReturnsOnceTrnrundExitsCleanly()
    {
        DaemonProcess process = Start();
        Exit(process);

        await process.WaitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(0, process.ExitCode);
        Assert.Throws<ClosedException>(() => process.Request("ready"));
    }

    /// <summary>Throw the exit code and diagnostics of a failed exit from WaitAsync().</summary>
    [Fact]
    public async Task WaitAsyncThrowsWhenTrnrundExitsWithAnError()
    {
        DaemonProcess process = Start();
        Exit(process, 2);

        var error = await Assert.ThrowsAsync<DaemonExitedException>(() => process.WaitAsync(CancellationToken.None));
        Assert.Equal("trnrund exited with code 2: bye", error.Message);
    }

    /// <summary>Stop waiting when cancelled, leaving trnrund running.</summary>
    [Fact]
    public async Task WaitAsyncIsCancelledAndLeavesTrnrundRunning()
    {
        DaemonProcess process = Start();
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => process.WaitAsync(cancel.Token));

        Assert.True(process.Request("ready").GetProperty("ok").GetBoolean());
    }

    /// <summary>Throw the exit code and diagnostics of a failed exit.</summary>
    [Fact]
    public void WaitThrowsWhenTrnrundExitsWithAnError()
    {
        DaemonProcess process = Start();
        Exit(process, 2);

        var error = Assert.Throws<DaemonExitedException>(() => process.Wait(TimeSpan.FromSeconds(10)));
        Assert.Equal("trnrund exited with code 2: bye", error.Message);
    }

    /// <summary>Return false without closing a daemon that has not exited, so a later crash is still reported.</summary>
    [Fact]
    public void WaitTimesOutAndLeavesTrnrundRunning()
    {
        DaemonProcess process = Start();

        Assert.False(process.Wait(TimeSpan.FromMilliseconds(50)));
        Assert.True(process.Request("ready").GetProperty("ok").GetBoolean());
        Assert.Contains("code 3", Assert.Throws<DaemonExitedException>(() => process.Request("crash")).Message);
        Assert.Contains("code 3", Assert.Throws<DaemonExitedException>(() => process.WaitForChanges(0, TimeSpan.Zero)).Message);
    }

    /// <summary>Close stdin, wait for the exit, and allow closing again.</summary>
    [Fact]
    public void CloseEndsTrnrundAndIsIdempotent()
    {
        DaemonProcess process = Start();
        process.Request("ready");

        process.Close();
        process.Close();

        Assert.Equal(0, process.ExitCode);
        Assert.Throws<ClosedException>(() => process.WaitForChanges(0, TimeSpan.Zero));
        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => process.Request("ready")).Message);
    }

    /// <summary>Let concurrent closes, blocking and not, wait for the same one closing.</summary>
    [Fact]
    public async Task ConcurrentClosesShareOneClosing()
    {
        DaemonProcess process = Start(["--ignore-eof"], closeWait: TimeSpan.FromMilliseconds(500));
        process.Request("ready");

        await Task.WhenAll(process.CloseAsync(), process.CloseAsync(), Task.Run(process.Close)).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.NotNull(process.ExitCode);
        Assert.Throws<ClosedException>(() => process.Request("ready"));
    }

    /// <summary>Close a daemon that already exited without throwing.</summary>
    [Fact]
    public void CloseAfterACrash()
    {
        DaemonProcess process = Start();
        Assert.Throws<DaemonExitedException>(() => process.Request("crash"));

        process.Close();

        Assert.Throws<ClosedException>(() => process.WaitForChanges(0, TimeSpan.Zero)); // Closed: its crash is no longer reported.
    }

    /// <summary>Kill a daemon still running after its close grace period, so closing never hangs.</summary>
    [Fact]
    public void CloseKillsATrnrundThatDoesNotExit()
    {
        DaemonProcess process = Start(["--ignore-eof"], closeWait: TimeSpan.FromMilliseconds(500));
        process.Request("ready");

        process.Close();

        Assert.NotEqual(0, process.ExitCode); // Killed, not exited.
        Assert.Throws<ClosedException>(() => process.WaitForChanges(0, TimeSpan.FromSeconds(5))); // Its stdout ended.
    }
}
