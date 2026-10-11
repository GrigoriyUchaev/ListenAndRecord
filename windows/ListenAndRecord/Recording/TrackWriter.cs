using NAudio.Wave;

namespace ListenAndRecord.Recording;

/// <summary>
/// Writes one source (microphone or system sound) to a mono float WAV, placing every buffer
/// at its timeline position: gaps become silence (Windows delivers nothing while no sound
/// is playing), so both tracks line up.
/// </summary>
public sealed class TrackWriter(string path, RecordingClock clock)
{
    private static readonly Guid PcmSubtype = new("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid FloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    private readonly object _lock = new();
    private WaveFileWriter? _writer;
    private int _rate;
    private long _written;
    private float _rms;
    private bool _finished;
    private double _lastFlush;

    public string Path { get; } = path;
    public bool HasData { get { lock (_lock) return _writer != null; } }
    public float Level { get { lock (_lock) return _rms; } }

    public void Append(byte[] buffer, int bytes, WaveFormat format)
    {
        double now = RecordingClock.Now;
        var mono = ToMono(buffer, bytes, format);
        if (mono.Length == 0) return;
        var position = clock.Position(now - mono.Length / (double)format.SampleRate);
        lock (_lock)
        {
            if (_finished) return;
            if (position is not double pos) { _rms = 0; return; }
            if (_writer == null)
            {
                _rate = format.SampleRate;
                _writer = new WaveFileWriter(Path, WaveFormat.CreateIeeeFloatWaveFormat(_rate, 1));
            }
            if (format.SampleRate != _rate) mono = Resample(mono, format.SampleRate, _rate);
            _rms = Rms(mono);

            long target = (long)(pos * _rate);
            long tolerance = (long)(0.2 * _rate);
            if (target - _written > tolerance) WriteSilence(target - _written);
            else if (_written - target > tolerance) return;   // device clock running ahead

            _writer.WriteSamples(mono, 0, mono.Length);
            _written += mono.Length;
            if (now - _lastFlush > 5)
            {
                _writer.Flush();   // keeps the file valid if the app is closed unexpectedly
                _lastFlush = now;
            }
        }
    }

    /// <summary>Pads the track to the given duration and closes the file.</summary>
    public void Finish(double duration)
    {
        lock (_lock)
        {
            if (_finished) return;
            _finished = true;
            if (_writer == null)
            {
                _rate = 48000;
                _writer = new WaveFileWriter(Path, WaveFormat.CreateIeeeFloatWaveFormat(_rate, 1));
            }
            long target = (long)(duration * _rate);
            if (target > _written) WriteSilence(target - _written);
            _writer.Dispose();
            _writer = null;
        }
    }

    private void WriteSilence(long frames)
    {
        var zeros = new float[Math.Min(frames, _rate)];
        while (frames > 0)
        {
            int n = (int)Math.Min(frames, zeros.Length);
            _writer!.WriteSamples(zeros, 0, n);
            _written += n;
            frames -= n;
        }
    }

    private static float[] ToMono(byte[] buffer, int bytes, WaveFormat format)
    {
        int channels = Math.Max(1, format.Channels);
        int bits = format.BitsPerSample;
        bool isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat ||
                       (format is WaveFormatExtensible ext && ext.SubFormat == FloatSubtype);
        bool isPcm = format.Encoding == WaveFormatEncoding.Pcm ||
                     (format is WaveFormatExtensible ext2 && ext2.SubFormat == PcmSubtype);
        if (!isFloat && !isPcm) return [];
        int bytesPerSample = bits / 8;
        int frames = bytes / (bytesPerSample * channels);
        var mono = new float[frames];
        for (int f = 0; f < frames; f++)
        {
            float sum = 0;
            for (int c = 0; c < channels; c++)
            {
                int o = (f * channels + c) * bytesPerSample;
                sum += isFloat && bits == 32 ? BitConverter.ToSingle(buffer, o)
                     : bits == 16 ? BitConverter.ToInt16(buffer, o) / 32768f
                     : bits == 24 ? ((buffer[o] | buffer[o + 1] << 8 | (sbyte)buffer[o + 2] << 16) / 8388608f)
                     : bits == 32 ? BitConverter.ToInt32(buffer, o) / 2147483648f
                     : 0;
            }
            mono[f] = sum / channels;
        }
        return mono;
    }

    private static float[] Resample(float[] input, int from, int to)
    {
        int n = (int)((long)input.Length * to / from);
        var output = new float[n];
        for (int i = 0; i < n; i++)
        {
            double src = (double)i * from / to;
            int i0 = (int)src;
            int i1 = Math.Min(i0 + 1, input.Length - 1);
            double frac = src - i0;
            output[i] = (float)(input[Math.Min(i0, input.Length - 1)] * (1 - frac) + input[i1] * frac);
        }
        return output;
    }

    private static float Rms(float[] data)
    {
        double sum = 0;
        foreach (var v in data) sum += v * v;
        return (float)Math.Sqrt(sum / Math.Max(1, data.Length));
    }
}
