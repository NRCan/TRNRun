using System.Diagnostics;
using System.Text.Json;
using TRNRun.Internal;
using TRNRun.Interop;

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

    /// <summary>Start trnrund with the given arguments, inside the kill-on-close job.</summary>
    [Fact]
    public void StartPassesTheArgumentsAndAssignsTheJob()
    {
        DaemonProcess process = Start(["--database:runs.sqlite3", "--maxConcurrent:2"]);

        JsonElement reply = process.Request("ready");

        Assert.Equal(
            ["--database:runs.sqlite3", "--maxConcurrent:2"],
            reply.GetProperty("args").EnumerateArray().Select(arg => arg.GetString()));
        using Process child = Process.GetProcessById(process.ProcessId);
        Assert.NotNull(WindowsJob.Shared);
        Assert.True(JobTests.IsInJob(child, WindowsJob.Shared));
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
    public void RejectedRequestThrowsArgumentException()
    {
        DaemonProcess process = Start();

        Assert.Equal("Rejected on purpose", Assert.Throws<ArgumentException>(() => process.Request("reject")).Message);
        Assert.Equal("trnrund rejected the request", Assert.Throws<ArgumentException>(() => process.Request("bare_reject")).Message);
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
    public void WaitForChangeWakesOnALaterRevision()
    {
        DaemonProcess process = Start();

        Assert.False(process.WaitForChange(0, TimeSpan.FromMilliseconds(50)));
        process.Request("notify", writer => writer.WriteNumber("revision", 5));

        Assert.True(process.WaitForChange(4, TimeSpan.FromSeconds(5)));
        Assert.False(process.WaitForChange(5, TimeSpan.FromMilliseconds(50)));
    }

    /// <summary>Never go back to an older revision announced late.</summary>
    [Fact]
    public void WaitForChangeKeepsTheLargestRevision()
    {
        DaemonProcess process = Start();
        process.Request("notify", writer => writer.WriteNumber("revision", 7));
        process.Request("notify", writer => writer.WriteNumber("revision", 3));

        Assert.True(process.WaitForChange(6, TimeSpan.FromMilliseconds(50)));
    }

    /// <summary>Wake a waiter blocked in another thread.</summary>
    [Fact]
    public void WaitForChangeFromAnotherThread()
    {
        DaemonProcess process = Start();
        bool? woke = null;
        var waiter = new Thread(() => woke = process.WaitForChange(0, TimeSpan.FromSeconds(10)));
        waiter.Start();

        process.Request("notify", writer => writer.WriteNumber("revision", 1));

        Assert.True(waiter.Join(TimeSpan.FromSeconds(10)));
        Assert.True(woke);
    }

    // -----------------------------------------------------------------
    // Exit
    // -----------------------------------------------------------------

    /// <summary>Throw DaemonException with the exit code and stderr, for this and every later request.</summary>
    [Fact]
    public void CrashIsReportedWithItsDiagnostics()
    {
        DaemonProcess process = Start();

        var error = Assert.Throws<DaemonException>(() => process.Request("crash"));
        Assert.Equal("trnrund exited with code 3: boom", error.Message);
        Assert.Equal((3, "boom"), (error.ExitCode, error.Diagnostics));
        Assert.Contains("code 3", Assert.Throws<DaemonException>(() => process.Request("ready")).Message);

        DaemonException? exitError = process.GetExitError();
        Assert.NotNull(exitError);
        Assert.Contains("boom", exitError.Message);
        Assert.True(process.WaitForChange(0, TimeSpan.FromSeconds(5))); // Its end wakes waiters.
    }

    /// <summary>Report no error for a daemon that is still serving.</summary>
    [Fact]
    public void ExitErrorIsNullWhileRunning()
    {
        DaemonProcess process = Start();
        process.Request("ready");

        Assert.Null(process.GetExitError());
    }

    /// <summary>Treat an exit after Wait() as expected, and close the process.</summary>
    [Fact]
    public void WaitReturnsOnceTrnrundExitsCleanly()
    {
        DaemonProcess process = Start();
        process.Request("exit");

        Assert.True(process.Wait(TimeSpan.FromSeconds(10)));
        Assert.Null(process.GetExitError());
        Assert.Equal("trnrund is closed", Assert.Throws<DaemonException>(() => process.Request("ready")).Message);
    }

    /// <summary>Throw the exit code and diagnostics of a failed exit.</summary>
    [Fact]
    public void WaitThrowsWhenTrnrundExitsWithAnError()
    {
        DaemonProcess process = Start();
        process.Request("exit", writer => writer.WriteNumber("code", 2));

        var error = Assert.Throws<DaemonException>(() => process.Wait(TimeSpan.FromSeconds(10)));
        Assert.Equal("trnrund exited with code 2: bye", error.Message);
    }

    /// <summary>Return false without closing a daemon that has not exited.</summary>
    [Fact]
    public void WaitTimesOutAndLeavesTrnrundRunning()
    {
        DaemonProcess process = Start();

        Assert.False(process.Wait(TimeSpan.FromMilliseconds(50)));
        Assert.True(process.Request("ready").GetProperty("ok").GetBoolean());
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
        Assert.Null(process.GetExitError());
        Assert.Equal("trnrund is closed", Assert.Throws<DaemonException>(() => process.Request("ready")).Message);
    }

    /// <summary>Close a daemon that already exited without throwing.</summary>
    [Fact]
    public void CloseAfterACrash()
    {
        DaemonProcess process = Start();
        Assert.Throws<DaemonException>(() => process.Request("crash"));

        process.Close();

        Assert.Null(process.GetExitError()); // Closed: its exit is no longer reported.
    }

    /// <summary>Kill a daemon still running after its close grace period, so closing never hangs.</summary>
    [Fact]
    public void CloseKillsATrnrundThatDoesNotExit()
    {
        DaemonProcess process = Start(["--ignore-eof"], closeWait: TimeSpan.FromMilliseconds(500));
        process.Request("ready");

        process.Close();

        Assert.NotEqual(0, process.ExitCode); // Killed, not exited.
        Assert.True(process.WaitForChange(0, TimeSpan.FromSeconds(5))); // Its stdout ended.
    }
}
