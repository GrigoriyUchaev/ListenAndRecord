using System.IO;

namespace ListenAndRecord.Transcription;

public sealed record TranscriptionStage(string Title, double Fraction)
{
    public static TranscriptionStage Preparing(double p) => new("Подготовка аудио…", 0.08 * p);
    public static TranscriptionStage Transcribing(int done, int total) =>
        new($"Распознавание речи: фрагмент {Math.Min(done + 1, total)} из {total}", 0.08 + 0.84 * done / Math.Max(total, 1));
    public static TranscriptionStage Recovering(int done, int total) =>
        new($"Проверка пропусков: повторное распознавание {Math.Min(done + 1, total)} из {total}", 0.92 + 0.08 * done / Math.Max(total, 1));
}

/// <summary>Full pipeline: decode → split at pauses → whisper → detect &amp; re-run lost fragments → clean up.</summary>
public sealed class TranscriptionPipeline(WhisperSettings settings, bool useVad, bool recoverGaps)
{
    /// <summary>Lives next to the models so that relative paths contain only Latin characters.</summary>
    public static string WorkRoot => Path.Combine(Core.AppSettings.Folder, "work");

    public async Task<Transcript> RunAsync(string source, Action<TranscriptionStage> progress, CancellationToken ct)
    {
        var work = Path.Combine(WorkRoot, Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(work);
        try
        {
            var audio = await Task.Run(() => AudioPreparer.Prepare(source, work, p => progress(TranscriptionStage.Preparing(p)), ct), ct);

            var runs = SpeechChunker.DetectSpeech(audio.Energies);
            if (runs.Count == 0) throw new InvalidOperationException("В файле не найдено речи (или он пустой).");
            runs = SpeechChunker.SplitLongRuns(runs, audio.Energies, 30 * 100, 15 * 100);
            var chunks = SpeechChunker.MakeChunks(runs, audio.SampleCount, 60, 2.0, 15);
            if (chunks.Count == 0) throw new InvalidOperationException("В файле не найдено речи (или он пустой).");

            using var reader = new PcmSliceReader(audio.PcmPath, audio.SampleCount);
            var files = Write(chunks, "chunk", work, reader);
            var whisper = new WhisperRunner(settings, work);

            progress(TranscriptionStage.Transcribing(0, chunks.Count));
            var local = await whisper.TranscribeAsync(files, useVad, d => progress(TranscriptionStage.Transcribing(d, chunks.Count)), ct);
            var cleaned = local.Select(l => TranscriptCleaner.Clean(l)).ToList();
            var perChunk = chunks.Select((c, i) => cleaned[i].Select(s => ToSource(s, c)).ToList()).ToList();

            if (recoverGaps)
            {
                var suspicious = Enumerable.Range(0, chunks.Count)
                    .Where(i => SpeechChunker.LooksIncomplete(cleaned[i], chunks[i].Duration)).ToList();
                for (int n = 0; n < suspicious.Count; n++)
                {
                    ct.ThrowIfCancellationRequested();
                    progress(TranscriptionStage.Recovering(n, suspicious.Count));
                    int i = suspicious[n];
                    var better = await RetranscribeAsync(chunks[i], i, work, reader, audio.Energies, perChunk[i], whisper, ct);
                    if (better != null) perChunk[i] = better;
                }
            }

            var segments = TranscriptCleaner.Clean(perChunk.SelectMany(x => x).OrderBy(s => s.Start), collapseLoops: false);
            return new Transcript
            {
                SourceName = Path.GetFileName(source),
                Duration = audio.Duration,
                Language = settings.Language,
                Segments = segments,
            };
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { }
        }
    }

    /// <summary>Re-runs a suspicious chunk as short pieces without VAD; kept only if it recovers more speech.</summary>
    private static async Task<List<TranscriptSegment>?> RetranscribeAsync(SpeechChunk chunk, int index, string work, PcmSliceReader reader,
        List<float> energies, List<TranscriptSegment> current, WhisperRunner whisper, CancellationToken ct)
    {
        var runs = SpeechChunker.SplitLongRuns(chunk.SpeechRuns, energies, 15 * 100, 8 * 100);
        var subChunks = SpeechChunker.MakeChunks(runs, reader.SampleCount, 20, 1.0, 5);
        if (subChunks.Count == 0) return null;
        var files = Write(subChunks, $"retry{index}", work, reader);
        var local = await whisper.TranscribeAsync(files, false, _ => { }, ct);
        var candidate = subChunks.SelectMany((sub, i) => TranscriptCleaner.Clean(local[i]).Select(s => ToSource(s, sub))).ToList();
        int before = current.Sum(s => s.WordCount), after = candidate.Sum(s => s.WordCount);
        return after > before * 1.15 + 3 ? candidate : null;
    }

    private static List<string> Write(List<SpeechChunk> chunks, string prefix, string dir, PcmSliceReader reader)
    {
        var files = new List<string>();
        for (int i = 0; i < chunks.Count; i++)
        {
            var path = Path.Combine(dir, $"{prefix}_{i:0000}.wav");
            reader.WriteWav(chunks[i].Pieces, path);
            files.Add(path);
        }
        return files;
    }

    private static TranscriptSegment ToSource(TranscriptSegment s, SpeechChunk chunk) =>
        s with { Start = chunk.SourceTime(s.Start), End = chunk.SourceTime(s.End) };
}
