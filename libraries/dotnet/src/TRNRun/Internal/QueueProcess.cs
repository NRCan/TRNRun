using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using TRNRun.Interop;

namespace TRNRun.Internal;

// Owns only transport and native resources; the manager must drain stdout before WaitForExit.
internal sealed class QueueProcess
{
    private readonly Process _process;
    private readonly WindowsJobObject? _job;
    private bool _inputClosed;

    internal QueueProcess(string executable, int maxConcurrent)
    {
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = false,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            StandardOutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        startInfo.ArgumentList.Add("--maxConcurrent:" + maxConcurrent.ToString(CultureInfo.InvariantCulture));
        _process = new Process { StartInfo = startInfo };
        bool started = false;
        try
        {
            started = _process.Start();
            if (!started)
            {
                throw new InvalidOperationException("TRNRun queue did not start.");
            }

            _process.StandardInput.NewLine = "\n";
            _job = WindowsJobObject.TryAssign(_process);
        }
        catch
        {
            // No submissions exist yet. Close input so a partially initialized queue exits.
            try
            {
                if (started)
                {
                    _process.StandardInput.Dispose();
                }
            }
            finally
            {
                _process.Dispose();
                _job?.Dispose();
            }

            throw;
        }
    }

    internal void Send(string runId, string deckPath, string runnerPath, string[] runnerArgs)
    {
        string request = JsonSerializer.Serialize(new
        {
            runID = runId,
            deckFile = deckPath,
            runnerPath,
            runnerArgs,
        });
        _process.StandardInput.WriteLine(request);
        _process.StandardInput.Flush();
    }

    internal string? ReadLine() => _process.StandardOutput.ReadLine();

    internal void CloseInput()
    {
        if (_inputClosed)
        {
            return;
        }

        _inputClosed = true;
        try
        {
            _process.StandardInput.Dispose();
        }
        catch (IOException)
        {
            // A queue that exited early may have broken stdin; still drain its output and reap it.
        }
    }

    internal int WaitForExit()
    {
        _process.WaitForExit();
        return _process.ExitCode;
    }

    internal void Abort()
    {
        // Used only when stdout cannot be drained, never for normal shutdown or a run's failure.
        try
        {
            _process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) when (_process.HasExited)
        {
            // The queue may have exited between the read failure and emergency cleanup.
        }

        _process.WaitForExit();
    }

    internal void Release()
    {
        try
        {
            CloseInput();
            _process.StandardOutput.Dispose();
        }
        finally
        {
            try
            {
                _process.Dispose();
            }
            finally
            {
                _job?.Dispose();
            }
        }
    }
}
