using System;
using System.Collections.Generic;
using System.IO;

namespace TRNRun.Internal;

/// <summary>Resolves executable paths shared by runner configuration and queue startup.</summary>
internal static class ExecutableResolver
{
    /// <summary>Resolves an explicit or bundled executable to an existing full path.</summary>
    /// <remarks>
    /// Explicit paths never fall back to bundled lookup. A null path searches runtimes/win-x64/native,
    /// native, and the flat directory under the application base, then beside the library. PATH is not searched.
    /// </remarks>
    internal static string Resolve(string? path, string fileName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);
        if (fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || !string.Equals(Path.GetExtension(fileName), ".exe", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Expected a bare .exe file name, not a path.", nameof(fileName));
        }

        if (path is not null)
        {
            return Validate(path, nameof(path));
        }

        var candidates = new List<string>();
        AddCandidates(candidates, AppContext.BaseDirectory, fileName);

        // Single-file applications may have no assembly location.
        string? libraryDirectory = Path.GetDirectoryName(typeof(ExecutableResolver).Assembly.Location);
        if (!string.IsNullOrEmpty(libraryDirectory))
        {
            AddCandidates(candidates, libraryDirectory, fileName);
        }

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException(
            $"Executable '{fileName}' was not found. Searched: {string.Join("; ", candidates)}. "
            + "Supply an explicit executable path or deploy the bundled native executable.",
            fileName);
    }

    /// <summary>Validates an explicit .exe file path and returns its absolute form.</summary>
    internal static string Validate(string path, string paramName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path, paramName);
        if (path.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
        {
            throw new ArgumentException("Expected an unquoted file path without invalid characters.", paramName);
        }

        string fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"File for '{paramName}' was not found: '{fullPath}'.", fullPath);
        }

        if (!string.Equals(Path.GetExtension(fullPath), ".exe", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("The executable must be an .exe file.", paramName);
        }

        return fullPath;
    }

    private static void AddCandidates(List<string> candidates, string directory, string fileName)
    {
        string[] paths =
        [
            Path.Combine(directory, "runtimes", "win-x64", "native", fileName),
            Path.Combine(directory, "native", fileName),
            Path.Combine(directory, fileName),
        ];

        foreach (string path in paths)
        {
            string fullPath = Path.GetFullPath(path);
            if (!candidates.Exists(candidate => string.Equals(candidate, fullPath, StringComparison.OrdinalIgnoreCase)))
            {
                candidates.Add(fullPath);
            }
        }
    }
}
