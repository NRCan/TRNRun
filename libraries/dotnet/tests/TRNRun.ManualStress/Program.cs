// Manual stress test: fast and slow simulations without plots, with tracking.
//
// Run from libraries/dotnet with:
//
//     dotnet run --project tests/TRNRun.ManualStress
//
// Requires TRNSYS, Type3830, and the bundled TRNRun/trnrund executables. The slow deck also requires its
// referenced TRNSYS weather file. Edit the configuration below for your installation. Deck copies and outputs
// are retained in runs/ beside the built program for inspection. Not a test project, so dotnet test skips it.

using System.Diagnostics;
using TRNRun;

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------
const string TrnexePath = @"C:\TRNSYS18\Exe\TrnEXE64.exe";
string fastDck = Path.Combine(AppContext.BaseDirectory, "dck", "fast_wo_plot_w_tracking.dck");
string slowDck = Path.Combine(AppContext.BaseDirectory, "dck", "slow_wo_plot_w_tracking.dck");
string dckFolder = Path.Combine(AppContext.BaseDirectory, "runs");

const int FastSimCount = 50;
const int SlowSimCount = 50;
const int Workers = 25;
TimeSpan pollInterval = TimeSpan.FromSeconds(0.1);

var settings = new SimulationSettings { TrnexePath = TrnexePath, WatchTmp = true };

// -----------------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------------
foreach (string source in new[] { TrnexePath, fastDck, slowDck })
{
    if (!File.Exists(source))
    {
        throw new FileNotFoundException($"File not found: {source}", source);
    }
}

Directory.CreateDirectory(dckFolder);
string[] dckFiles = [.. CopyDck(fastDck, dckFolder, FastSimCount), .. CopyDck(slowDck, dckFolder, SlowSimCount)];

Console.WriteLine($"Running {FastSimCount:N0} fast + {SlowSimCount:N0} slow simulations (workers: {Workers}).");

var clock = Stopwatch.StartNew();
var failed = new List<Simulation>();
await using (TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(Workers))
{
    foreach (string dck in dckFiles)
    {
        await daemon.AddAsync(dck, settings);
    }

    // Each finished run is released once collected, so every poll returns only the newly finished ones.
    int finished = 0;
    var sinceStatus = Stopwatch.StartNew();
    while (finished < dckFiles.Length)
    {
        await Task.Delay(pollInterval);
        foreach (Simulation sim in await daemon.GetSimulationsAsync(SimulationState.Finished))
        {
            finished++;
            Console.WriteLine($"[{finished}/{dckFiles.Length}] {Path.GetFileName(sim.DeckFile)}: {sim.Status}");
            if (sim.Succeeded != true)
            {
                failed.Add(sim);
            }

            await daemon.ReleaseAsync(sim.SimId);
        }

        if (sinceStatus.Elapsed >= TimeSpan.FromSeconds(1))
        {
            sinceStatus.Restart();
            int queued = (await daemon.GetSimulationsAsync(SimulationState.Queued)).Count;
            int running = (await daemon.GetSimulationsAsync(SimulationState.Running)).Count;
            Console.WriteLine($"  {clock.Elapsed:mm\\:ss}  {queued} queued, {running} running, {finished}/{dckFiles.Length} finished");
        }
    }
}

double elapsed = clock.Elapsed.TotalSeconds;

Console.WriteLine(
    $"Finished in {elapsed:F1}s: {dckFiles.Length - failed.Count:N0}/{dckFiles.Length:N0} succeeded, {failed.Count:N0} failed.");

foreach (Simulation sim in failed)
{
    string error = string.IsNullOrEmpty(sim.Error) ? sim.StatusMessage ?? "" : sim.Error;
    Console.WriteLine($"FAILED {Path.GetFileName(sim.DeckFile)}: status={sim.Status}, error={error}");
}

return failed.Count == 0 ? 0 : 1;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// Copies a deck with unique, zero-padded names for independent outputs.
static string[] CopyDck(string src, string dstDir, int n) =>
    [.. Enumerable.Range(1, n).Select(i =>
    {
        string dst = Path.Combine(dstDir, $"{Path.GetFileNameWithoutExtension(src)}_{i:0000}{Path.GetExtension(src)}");
        File.Copy(src, dst, overwrite: true);
        return dst;
    })];
