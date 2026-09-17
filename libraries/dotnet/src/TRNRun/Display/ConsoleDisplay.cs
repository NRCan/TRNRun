using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace TRNRun.Display;

/// <summary>Renders manager-supplied state synchronously without owning simulations or background work.</summary>
internal sealed class ConsoleDisplay
{
    private const int PathWidth = 32;
    private const int ProgressBarWidth = 20;

    private readonly TimeSpan _refreshInterval;
    private long? _lastRenderTimestamp;
    private string? _lastFrame;

    internal ConsoleDisplay(TimeSpan refreshInterval)
    {
        if (refreshInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(refreshInterval), "The refresh interval must be positive.");
        }

        _refreshInterval = refreshInterval;
    }

    /// <summary>Writes a changed frame when due; force bypasses both throttling and change detection.</summary>
    internal void Render(IReadOnlyList<Simulation> simulations, bool force = false)
    {
        ArgumentNullException.ThrowIfNull(simulations);
        long now = Stopwatch.GetTimestamp();
        if (!force
            && _lastRenderTimestamp is long previous
            && Stopwatch.GetElapsedTime(previous, now) < _refreshInterval)
        {
            return;
        }

        StringBuilder frame = new();
        foreach (Simulation simulation in simulations)
        {
            frame.AppendLine(RenderLine(simulation));
        }

        string output = frame.ToString();
        if (output.Length > 0 && (force || !string.Equals(output, _lastFrame, StringComparison.Ordinal)))
        {
            // Append plain-text frames instead of moving the cursor, so redirected output works too.
            Console.Write(output);
        }

        _lastFrame = output;
        _lastRenderTimestamp = now;
    }

    private static string RenderLine(Simulation simulation)
    {
        string id = SingleLine(simulation.Id);
        string path = FormatPath(simulation.DeckPath);
        string status = SingleLine(simulation.Status?.Status ?? "-");
        ProgressEvent? progress = simulation.Progress;
        ConfigEvent? config = simulation.ConfigEvent;

        string elapsed = FormatDuration(progress?.Elapsed);
        string eta = FormatDuration(progress?.Eta);
        double? percent = progress is not null && double.IsFinite(progress.Percent) ? progress.Percent : null;
        int filled = (int)(Math.Clamp(percent ?? 0, 0, 1) * ProgressBarWidth);
        string bar = "[" + new string('#', filled) + new string('-', ProgressBarWidth - filled) + "]";
        string percentage = percent is double fraction
            ? string.Create(CultureInfo.InvariantCulture, $"({fraction * 100:0}%)")
            : string.Empty;
        string simulationProgress = progress is not null && config is not null
            ? string.Create(CultureInfo.InvariantCulture, $"{progress.Time,6:N0} / {config.Stop,6:N0}")
            : "- / -";

        return string.Create(
            CultureInfo.InvariantCulture,
            $"[{id}] {path} | Status: {status,-10} | Logs: N:{simulation.Notices} W:{simulation.Warnings} F:{simulation.Fatals} | Elapsed: {elapsed} | ETA: {eta} | {bar} {simulationProgress} {percentage}");
    }

    private static string FormatDuration(double? milliseconds)
    {
        if (milliseconds is not double value || !double.IsFinite(value))
        {
            return "--:--:--";
        }

        // Work with total hours rather than TimeSpan.Hours so multi-day runs do not wrap at 24 hours.
        double totalSeconds = Math.Floor(Math.Max(value, 0) / 1000);
        double hours = Math.Floor(totalSeconds / 3600);
        double minutes = Math.Floor(totalSeconds % 3600 / 60);
        double seconds = totalSeconds % 60;
        return string.Create(CultureInfo.InvariantCulture, $"{hours:00}:{minutes:00}:{seconds:00}");
    }

    private static string FormatPath(string path)
    {
        string text = SingleLine(path);
        return text.Length <= PathWidth ? text.PadRight(PathWidth) : "..." + text[^(PathWidth - 3)..];
    }

    private static string SingleLine(string text)
    {
        StringBuilder result = new(text.Length);
        foreach (char character in text)
        {
            // Native strings are data, not terminal escape sequences or additional console lines.
            result.Append(char.IsControl(character) || character is '\u2028' or '\u2029' ? ' ' : character);
        }

        return result.ToString();
    }
}
