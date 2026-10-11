using System.Diagnostics;

namespace ListenAndRecord.Recording;

/// <summary>
/// Maps wall-clock instants onto the recording timeline, skipping paused intervals.
/// Both tracks (microphone and system sound) use the same clock so they stay aligned.
/// </summary>
public sealed class RecordingClock
{
    private readonly object _lock = new();
    private readonly List<(double Start, double End)> _pauses = new();
    private double _start;
    private double? _pauseStart;

    public static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public void Start() { lock (_lock) { _start = Now; _pauses.Clear(); _pauseStart = null; } }

    public void Pause() { lock (_lock) { _pauseStart ??= Now; } }

    public void Resume()
    {
        lock (_lock)
        {
            if (_pauseStart is double p) { _pauses.Add((p, Now)); _pauseStart = null; }
        }
    }

    public bool IsPaused { get { lock (_lock) return _pauseStart != null; } }

    /// <summary>Position on the recording timeline, or null when the instant falls inside a pause.</summary>
    public double? Position(double t)
    {
        lock (_lock)
        {
            if (_pauseStart is double p && t >= p) return null;
            double paused = 0;
            foreach (var r in _pauses)
            {
                if (t >= r.End) paused += r.End - r.Start;
                else if (t >= r.Start) return null;
            }
            return Math.Max(0, t - _start - paused);
        }
    }

    public double Elapsed
    {
        get
        {
            lock (_lock)
            {
                double end = _pauseStart ?? Now;
                return Math.Max(0, end - _start - _pauses.Sum(r => r.End - r.Start));
            }
        }
    }
}
