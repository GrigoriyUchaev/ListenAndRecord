using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace ListenAndRecord.Transcription;

public sealed record WhisperSettings(
    string ModelPath,
    string? VadModelPath,     // null = Silero VAD off
    string Language,          // "auto", "ru", "en", ...
    int Threads,
    int BeamSize);            // 1 = greedy (fast), 5 = beam search (accurate)

/// <summary>
/// Runs the whisper.cpp engine bundled with the app (whisper\whisper-cli.exe) on a batch of
/// WAV files, with settings chosen to avoid losing speech after pauses.
/// </summary>
public sealed class WhisperRunner(WhisperSettings settings, string workDir)
{
    public static string ExecutablePath => Path.Combine(AppContext.BaseDirectory, "whisper", "whisper-cli.exe");

    public WhisperSettings Settings { get; } = settings;

    /// <summary>Transcribes each file independently; returns segments in file-local time.</summary>
    public async Task<List<List<TranscriptSegment>>> TranscribeAsync(IReadOnlyList<string> files, bool useVad,
        Action<int> onFileDone, CancellationToken ct)
    {
        var results = new List<List<TranscriptSegment>>();
        const int batchSize = 16;    // one model load per batch
        int done = 0;
        for (int b = 0; b < files.Count; b += batchSize)
        {
            ct.ThrowIfCancellationRequested();
            var batch = files.Skip(b).Take(batchSize).ToList();
            int baseDone = done;
            await RunAsync(batch, useVad, started => onFileDone(baseDone + Math.Max(0, started - 1)), ct);
            foreach (var f in batch) results.Add(ReadOutput(f));
            done += batch.Count;
            onFileDone(done);
        }
        return results;
    }

    /// <summary>
    /// whisper-cli reads its arguments in the ANSI code page, so non-Latin characters in paths
    /// (e.g. a Cyrillic user name) would break. All paths are therefore passed relative to the
    /// working directory, which lives next to the models.
    /// </summary>
    private string Rel(string path)
    {
        var rel = Path.GetRelativePath(workDir, path);
        return rel.All(c => c < 128) ? rel : path;
    }

    private List<string> Arguments(IReadOnlyList<string> batch, bool useVad)
    {
        var args = new List<string>
        {
            "-m", Rel(Settings.ModelPath),
            "-l", Settings.Language,
            "-t", Settings.Threads.ToString(),
            "-bs", Settings.BeamSize.ToString(),
            "-bo", "5",
            "-oj", "-otxt",
            // Do not condition on previously decoded text: the main reason Whisper gets
            // stuck or skips the rest of the audio after a pause.
            "-mc", "0",
            "-sns",
        };
        if (useVad && Settings.VadModelPath != null)
        {
            // Softer than the defaults so quiet speech is not discarded.
            args.AddRange(["--vad", "-vm", Rel(Settings.VadModelPath), "-vt", "0.4", "-vsd", "300", "-vp", "200"]);
        }
        foreach (var f in batch) { args.Add("-f"); args.Add(Rel(f)); }
        return args;
    }

    private async Task RunAsync(IReadOnlyList<string> batch, bool useVad, Action<int> onFileStarted, CancellationToken ct)
    {
        if (!File.Exists(ExecutablePath))
            throw new InvalidOperationException($"Не найден встроенный распознаватель: {ExecutablePath}. Переустановите приложение.");

        var psi = new ProcessStartInfo(ExecutablePath)
        {
            WorkingDirectory = workDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            StandardErrorEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var a in Arguments(batch, useVad)) psi.ArgumentList.Add(a);

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var tail = new Queue<string>();
        int started = 0;
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (tail)
            {
                tail.Enqueue(e.Data);
                while (tail.Count > 15) tail.Dequeue();
            }
            if (e.Data.Contains("processing '")) onFileStarted(Interlocked.Increment(ref started));
        };
        process.OutputDataReceived += (_, _) => { };

        process.Start();
        try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        try
        {
            await process.WaitForExitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(true); } catch { }
            throw;
        }
        if (process.ExitCode != 0)
        {
            string log;
            lock (tail) log = string.Join("\n", tail);
            throw new InvalidOperationException($"Распознаватель завершился с ошибкой (код {process.ExitCode}).\n{log}");
        }
    }

    public static List<TranscriptSegment> ReadOutput(string file)
    {
        foreach (var json in new[] { file + ".json", Path.ChangeExtension(file, ".json") })
        {
            if (!File.Exists(json)) continue;
            var parsed = ParseJson(File.ReadAllBytes(json));
            if (parsed != null) return parsed;
        }
        foreach (var txt in new[] { file + ".txt", Path.ChangeExtension(file, ".txt") })
        {
            if (!File.Exists(txt)) continue;
            var text = string.Join(" ", File.ReadAllLines(txt, Encoding.UTF8)).Trim();
            return text.Length == 0 ? [] : [new TranscriptSegment(0, 0, text)];
        }
        throw new InvalidOperationException($"Распознаватель не создал результат для {Path.GetFileName(file)}.");
    }

    public static List<TranscriptSegment>? ParseJson(byte[] raw)
    {
        try
        {
            // whisper may emit invalid UTF-8 when a token splits a character; decoding repairs it.
            using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(raw));
            if (!doc.RootElement.TryGetProperty("transcription", out var items)) return null;
            var list = new List<TranscriptSegment>();
            foreach (var item in items.EnumerateArray())
            {
                var text = item.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "";
                double from = 0, to = 0;
                if (item.TryGetProperty("offsets", out var off))
                {
                    from = off.TryGetProperty("from", out var f) ? f.GetDouble() / 1000 : 0;
                    to = off.TryGetProperty("to", out var tt) ? tt.GetDouble() / 1000 : from;
                }
                list.Add(new TranscriptSegment(from, Math.Max(from, to), text.Trim()));
            }
            return list;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
