using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using TRNRun.Interop;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="WindowsJob"/>: the kill-on-close Windows Job Object.</summary>
public sealed partial class JobTests : IDisposable
{
    private readonly Process _sleeper;

    /// <summary>Starts a child that runs until it is killed: the fake trnrund, ignoring end of input.</summary>
    public JobTests()
    {
        _sleeper = Process.Start(new ProcessStartInfo(Executables.FakeTrnrund, "--ignore-eof")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
        })!;
    }

    /// <summary>Kills the child if it is still running.</summary>
    public void Dispose()
    {
        if (!_sleeper.HasExited)
        {
            _sleeper.Kill();
            _sleeper.WaitForExit();
        }

        _sleeper.Dispose();
    }

    /// <summary>Returns whether <paramref name="process"/> belongs to <paramref name="job"/>.</summary>
    internal static bool IsInJob(Process process, SafeFileHandle job)
    {
        Assert.True(IsProcessInJob(process.SafeHandle, job, out bool result));
        return result;
    }

    /// <summary>Put a started child in the process-wide job.</summary>
    [Fact]
    public void TryAssignAddsTheProcessToTheSharedJob()
    {
        Assert.True(WindowsJob.TryAssign(_sleeper));

        Assert.NotNull(WindowsJob.Shared);
        Assert.True(IsInJob(_sleeper, WindowsJob.Shared));
    }

    /// <summary>Reuse the same job for every child.</summary>
    [Fact]
    public void SharedIsOneJobPerProcess() =>
        Assert.Same(WindowsJob.Shared, WindowsJob.Shared);

    /// <summary>Kill every member once the last job handle closes, as when this process dies.</summary>
    [Fact]
    public void ClosingTheJobKillsItsMembers()
    {
        SafeFileHandle? job = WindowsJob.Create();
        Assert.NotNull(job);
        Assert.True(AssignProcessToJobObject(job, _sleeper.SafeHandle));

        job.Dispose();

        Assert.True(_sleeper.WaitForExit(TimeSpan.FromSeconds(10)));
    }

    /// <summary>Report a process that already exited through the return value.</summary>
    [Fact]
    public void AssignFailureIsNeverThrown()
    {
        _sleeper.Kill();
        _sleeper.WaitForExit();

        Assert.False(WindowsJob.TryAssign(_sleeper));
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsProcessInJob(
        SafeProcessHandle process, SafeFileHandle job, [MarshalAs(UnmanagedType.Bool)] out bool result);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);
}
