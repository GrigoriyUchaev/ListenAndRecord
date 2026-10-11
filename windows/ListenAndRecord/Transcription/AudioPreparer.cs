using System.IO;
using System.Runtime.InteropServices;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ListenAndRecord.Transcription;

public sealed record PreparedAudio(string PcmPath, int SampleCount, List<float> Energies)
{
    public double Duration => SampleCount / SpeechChunker.SampleRate;
}

/// <summary>
/// Decodes any audio/video file Windows understands (m4a, mp3, wav, wma, mp4…) into raw
/// 16 kHz mono 16-bit samples, measuring frame energies on the way.
/// </summary>
public static class AudioPreparer
{
    public static PreparedAudio Prepare(string source, string workDir, Action<double> progress, CancellationToken ct)
    {
        using WaveStream reader = Open(source);
        var total = reader.TotalTime.TotalSeconds;
        ISampleProvider sp = new MonoSampleProvider(reader.ToSampleProvider());
        if (sp.WaveFormat.SampleRate != 16000) sp = new WdlResamplingSampleProvider(sp, 16000);

        var pcmPath = Path.Combine(workDir, "source.pcm");
        var energy = new EnergyAccumulator();
        int samples = 0;
        double lastReported = -1;
        var floats = new float[16000];
        var shorts = new short[16000];
        using (var fs = new FileStream(pcmPath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20))
        {
            int n;
            while ((n = sp.Read(floats, 0, floats.Length)) > 0)
            {
                ct.ThrowIfCancellationRequested();
                for (int i = 0; i < n; i++) shorts[i] = (short)Math.Clamp(floats[i] * 32767f, -32768f, 32767f);
                var span = shorts.AsSpan(0, n);
                fs.Write(MemoryMarshal.AsBytes(span));
                energy.Add(span);
                samples += n;
                if (total > 0)
                {
                    var p = Math.Min(1, samples / 16000.0 / total);
                    if (p - lastReported >= 0.01) { lastReported = p; progress(p); }
                }
            }
        }
        energy.Finish();
        progress(1);
        return new PreparedAudio(pcmPath, samples, energy.Energies);
    }

    public static double? Duration(string path)
    {
        try { using var r = Open(path); return r.TotalTime.TotalSeconds; }
        catch { return null; }
    }

    private static WaveStream Open(string path)
    {
        if (Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase))
        {
            try { return new WaveFileReader(path); } catch { /* fall back to Media Foundation */ }
        }
        return new MediaFoundationReader(path);
    }
}

/// <summary>Averages all channels into one.</summary>
public sealed class MonoSampleProvider : ISampleProvider
{
    private readonly ISampleProvider _source;
    private readonly int _channels;
    private float[] _buffer = [];

    public MonoSampleProvider(ISampleProvider source)
    {
        _source = source;
        _channels = source.WaveFormat.Channels;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(float[] buffer, int offset, int count)
    {
        if (_channels == 1) return _source.Read(buffer, offset, count);
        int needed = count * _channels;
        if (_buffer.Length < needed) _buffer = new float[needed];
        int read = _source.Read(_buffer, 0, needed);
        int frames = read / _channels;
        for (int f = 0; f < frames; f++)
        {
            float sum = 0;
            for (int c = 0; c < _channels; c++) sum += _buffer[f * _channels + c];
            buffer[offset + f] = sum / _channels;
        }
        return frames;
    }
}

/// <summary>Random access to the 16 kHz mono 16-bit samples produced by <see cref="AudioPreparer"/>.</summary>
public sealed class PcmSliceReader : IDisposable
{
    private readonly FileStream _fs;
    public int SampleCount { get; }

    public PcmSliceReader(string path, int sampleCount)
    {
        _fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        SampleCount = sampleCount;
    }

    public void Dispose() => _fs.Dispose();

    /// <summary>Writes the concatenation of pieces as a 16 kHz mono 16-bit WAV file.</summary>
    public void WriteWav(IEnumerable<AudioPiece> pieces, string destination)
    {
        using var writer = new WaveFileWriter(destination, new WaveFormat(16000, 16, 1));
        var buffer = new byte[1 << 16];
        foreach (var piece in pieces)
        {
            long start = Math.Clamp(piece.Start, 0, SampleCount);
            long end = Math.Clamp((long)piece.Start + piece.Length, start, SampleCount);
            _fs.Position = start * 2;
            long remaining = (end - start) * 2;
            while (remaining > 0)
            {
                int n = _fs.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                if (n <= 0) break;
                writer.Write(buffer, 0, n);
                remaining -= n;
            }
        }
    }
}
