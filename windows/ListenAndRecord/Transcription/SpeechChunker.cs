namespace ListenAndRecord.Transcription;

/// <summary>A contiguous range of samples in the 16 kHz source audio.</summary>
public readonly record struct AudioPiece(int Start, int Length);

/// <summary>A unit of work for Whisper: source pieces glued together, long pauses removed.</summary>
public sealed class SpeechChunk(List<AudioPiece> pieces, List<(int Lo, int Hi)> speechRuns)
{
    public List<AudioPiece> Pieces { get; } = pieces;
    public List<(int Lo, int Hi)> SpeechRuns { get; } = speechRuns;   // 10 ms frames, [Lo, Hi)

    public int TotalSamples => Pieces.Sum(p => p.Length);
    public double Duration => TotalSamples / SpeechChunker.SampleRate;
    public double SourceEnd => Pieces.Count == 0 ? 0 : (Pieces[^1].Start + Pieces[^1].Length) / SpeechChunker.SampleRate;

    /// <summary>Converts a time inside the chunk into a time in the source audio.</summary>
    public double SourceTime(double local)
    {
        var remaining = Math.Max(0, (int)Math.Round(local * SpeechChunker.SampleRate));
        foreach (var p in Pieces)
        {
            if (remaining <= p.Length) return (p.Start + remaining) / SpeechChunker.SampleRate;
            remaining -= p.Length;
        }
        return SourceEnd;
    }
}

public static class SpeechChunker
{
    public const double SampleRate = 16000;
    public const int FrameSamples = 160;      // 10 ms
    public const int FramesPerSecond = 100;

    /// <summary>
    /// Conservative energy-based voice activity detection, tuned never to drop quiet speech:
    /// only clearly silent stretches are removed.
    /// </summary>
    public static List<(int Lo, int Hi)> DetectSpeech(IReadOnlyList<float> energies)
    {
        int n = energies.Count;
        var result = new List<(int, int)>();
        if (n == 0) return result;
        var db = energies.Select(e => 20 * Math.Log10(Math.Max(e, 1e-7))).ToArray();
        var audible = db.Where(d => d > -90).OrderBy(d => d).ToArray();
        if (audible.Length < 10) return result;
        double Pct(double p) => audible[Math.Min(audible.Length - 1, (int)((audible.Length - 1) * p))];
        double noise = Pct(0.10), loud = Pct(0.95);
        if (loud <= -75) return result;
        if (loud - noise < 10)
        {
            int first = Array.FindIndex(db, d => d > -90), last = Array.FindLastIndex(db, d => d > -90);
            if (first >= 0) result.Add((first, last + 1));
            return result;
        }
        double threshold = noise + Math.Min(15, Math.Max(6, (loud - noise) * 0.25));

        var raw = new List<(int Lo, int Hi)>();
        int i = 0;
        while (i < n)
        {
            if (db[i] > threshold)
            {
                int s = i;
                while (i < n && db[i] > threshold) i++;
                if (i - s >= 5) raw.Add((s, i));       // ignore clicks < 50 ms
            }
            else i++;
        }

        const int padBefore = 25, padAfter = 45, mergeGap = 30;
        foreach (var r in raw)
        {
            int lo = Math.Max(0, r.Lo - padBefore), hi = Math.Min(n, r.Hi + padAfter);
            if (result.Count > 0 && lo - result[^1].Item2 <= mergeGap)
                result[^1] = (result[^1].Item1, Math.Max(result[^1].Item2, hi));
            else
                result.Add((lo, hi));
        }
        return result;
    }

    /// <summary>Splits runs longer than maxFrames at the quietest moment between minFrames and maxFrames.</summary>
    public static List<(int Lo, int Hi)> SplitLongRuns(List<(int Lo, int Hi)> runs, IReadOnlyList<float> energies, int maxFrames, int minFrames)
    {
        var output = new List<(int, int)>();
        const int window = 20;
        foreach (var r in runs)
        {
            int start = r.Lo;
            while (r.Hi - start > maxFrames)
            {
                int lo = start + minFrames, hi = Math.Min(start + maxFrames, energies.Count);
                int best = hi;
                float bestEnergy = float.MaxValue;
                for (int f = lo; f + window <= hi; f += 5)
                {
                    float sum = 0;
                    for (int k = f; k < f + window; k++) sum += energies[k];
                    if (sum < bestEnergy) { bestEnergy = sum; best = f + window / 2; }
                }
                if (best <= start) best = Math.Min(start + maxFrames, r.Hi);
                output.Add((start, best));
                start = best;
            }
            if (start < r.Hi) output.Add((start, r.Hi));
        }
        return output;
    }

    /// <summary>Groups speech runs into chunks of at most maxSeconds, preferring to cut at long pauses.</summary>
    public static List<SpeechChunk> MakeChunks(List<(int Lo, int Hi)> runs, int totalSamples, double maxSeconds,
        double splitGapSeconds, double minSecondsBeforeGapSplit, double keepGapSeconds = 1.2)
    {
        var chunks = new List<SpeechChunk>();
        var current = new List<(int Lo, int Hi)>();

        void Flush()
        {
            if (current.Count == 0) return;
            chunks.Add(Build(current, totalSamples, keepGapSeconds));
            current = new List<(int, int)>();
        }

        foreach (var r in runs)
        {
            if (current.Count > 0)
            {
                double gap = (r.Lo - current[^1].Hi) / (double)FramesPerSecond;
                double span = (r.Hi - current[0].Lo) / (double)FramesPerSecond;
                double currentSpan = (current[^1].Hi - current[0].Lo) / (double)FramesPerSecond;
                if (span > maxSeconds || (gap >= splitGapSeconds && currentSpan >= minSecondsBeforeGapSplit)) Flush();
            }
            current.Add(r);
        }
        Flush();
        return chunks.Where(c => c.TotalSamples > 0.2 * SampleRate).ToList();
    }

    private static SpeechChunk Build(List<(int Lo, int Hi)> runs, int totalSamples, double keepGapSeconds)
    {
        var pieces = new List<AudioPiece>();
        int? previousEnd = null;
        foreach (var r in runs)
        {
            int s = Math.Min(r.Lo * FrameSamples, totalSamples), e = Math.Min(r.Hi * FrameSamples, totalSamples);
            if (e <= s) continue;
            if (previousEnd is int pe && pieces.Count > 0 && (s - pe) / SampleRate <= keepGapSeconds)
                pieces[^1] = new AudioPiece(pieces[^1].Start, e - pieces[^1].Start);
            else
                pieces.Add(new AudioPiece(s, e - s));
            previousEnd = e;
        }
        return new SpeechChunk(pieces, new List<(int, int)>(runs));
    }

    /// <summary>Detects "Whisper stopped transcribing": too few words or a long stretch without text.</summary>
    public static bool LooksIncomplete(IReadOnlyList<TranscriptSegment> segments, double chunkDuration)
    {
        if (chunkDuration < 8) return false;
        int words = segments.Sum(s => s.WordCount);
        if (words < chunkDuration * 0.5) return true;
        double cursor = 0;
        foreach (var s in segments.OrderBy(s => s.Start))
        {
            if (s.Start - cursor > 8) return true;
            cursor = Math.Max(cursor, s.End);
        }
        return chunkDuration - cursor > 8;
    }
}

/// <summary>RMS energy of consecutive 10 ms frames, computed while audio streams through.</summary>
public sealed class EnergyAccumulator
{
    public List<float> Energies { get; } = new();
    private double _sum;
    private int _count;

    public void Add(ReadOnlySpan<short> samples)
    {
        foreach (var s in samples)
        {
            double v = s / 32768.0;
            _sum += v * v;
            if (++_count == SpeechChunker.FrameSamples) FlushFrame();
        }
    }

    public void Finish() { if (_count > 0) FlushFrame(); }

    private void FlushFrame()
    {
        Energies.Add((float)Math.Sqrt(_sum / _count));
        _sum = 0;
        _count = 0;
    }
}
