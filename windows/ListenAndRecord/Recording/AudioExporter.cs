using System.IO;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ListenAndRecord.Recording;

public static class AudioExporter
{
    public static readonly (string Ext, string Title)[] Formats =
    [
        ("m4a", "M4A (AAC) — компактный, отличное качество"),
        ("mp3", "MP3 — открывается везде"),
        ("wav", "WAV — без сжатия, максимальное качество"),
    ];

    private const int Rate = 48000;

    /// <summary>Mixes the tracks into one file. Two passes: find the peak, then write with a safe gain.</summary>
    public static void Export(IReadOnlyList<string> tracks, string format, string destination, Action<double> progress)
    {
        if (tracks.Count == 0) throw new InvalidOperationException("Запись пуста.");
        var temp = Path.Combine(Path.GetTempPath(), $"ListenAndRecord-{Guid.NewGuid():N}.wav");
        try
        {
            float peak = 0;
            long total = 0;
            Mix(tracks, (buf, n, done, all) =>
            {
                for (int i = 0; i < n; i++) peak = Math.Max(peak, Math.Abs(buf[i]));
                total = all;
                progress(0.3 * done / Math.Max(1, all));
            });
            float gain = peak > 0 ? Math.Min(4f, 0.89f / peak) : 1f;   // ≈ -1 dBFS ceiling

            using (var writer = new WaveFileWriter(temp, new WaveFormat(Rate, 16, 1)))
            {
                Mix(tracks, (buf, n, done, all) =>
                {
                    for (int i = 0; i < n; i++) buf[i] = Math.Clamp(buf[i] * gain, -1f, 1f);
                    writer.WriteSamples(buf, 0, n);
                    progress(0.3 + (format == "wav" ? 0.7 : 0.4) * done / Math.Max(1, all));
                });
            }

            if (File.Exists(destination)) File.Delete(destination);
            switch (format)
            {
                case "wav":
                    File.Move(temp, destination);
                    break;
                case "m4a":
                case "mp3":
                    MediaFoundationApi.Startup();
                    using (var reader = new WaveFileReader(temp))
                    {
                        try
                        {
                            if (format == "m4a") MediaFoundationEncoder.EncodeToAac(reader, destination, 128000);
                            else MediaFoundationEncoder.EncodeToMp3(reader, destination, 128000);
                        }
                        catch (Exception ex)
                        {
                            throw new InvalidOperationException(
                                $"Windows не смог закодировать {format.ToUpperInvariant()} ({ex.Message}). " +
                                "Сохраните в WAV или установите «Пакет дополнительных компонентов мультимедиа» (для выпусков Windows N).", ex);
                        }
                    }
                    break;
            }
            progress(1);
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
        }
    }

    private delegate void ChunkHandler(float[] buffer, int count, long done, long total);

    private static void Mix(IReadOnlyList<string> tracks, ChunkHandler handler)
    {
        var readers = tracks.Select(t => new WaveFileReader(t)).ToList();
        try
        {
            var sources = readers.Select(r =>
            {
                ISampleProvider sp = new MonoOf(r.ToSampleProvider());
                return sp.WaveFormat.SampleRate == Rate ? sp : new WdlResamplingSampleProvider(sp, Rate);
            }).ToList();
            long total = (long)(readers.Max(r => r.TotalTime.TotalSeconds) * Rate);
            var mix = new float[Rate];
            var tmp = new float[Rate];
            var ended = new bool[sources.Count];
            long done = 0;
            while (true)
            {
                Array.Clear(mix);
                int produced = 0;
                for (int s = 0; s < sources.Count; s++)
                {
                    if (ended[s]) continue;
                    int n = sources[s].Read(tmp, 0, tmp.Length);
                    if (n == 0) { ended[s] = true; continue; }
                    for (int i = 0; i < n; i++) mix[i] += tmp[i];
                    produced = Math.Max(produced, n);
                }
                if (produced == 0) break;
                done += produced;
                handler(mix, produced, done, Math.Max(total, done));
            }
        }
        finally
        {
            foreach (var r in readers) r.Dispose();
        }
    }

    /// <summary>Averages channels (tracks are mono already, this is just a safeguard).</summary>
    private sealed class MonoOf(ISampleProvider source) : ISampleProvider
    {
        private readonly int _channels = source.WaveFormat.Channels;
        private float[] _buf = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(float[] buffer, int offset, int count)
        {
            if (_channels == 1) return source.Read(buffer, offset, count);
            if (_buf.Length < count * _channels) _buf = new float[count * _channels];
            int read = source.Read(_buf, 0, count * _channels) / _channels;
            for (int f = 0; f < read; f++)
            {
                float sum = 0;
                for (int c = 0; c < _channels; c++) sum += _buf[f * _channels + c];
                buffer[offset + f] = sum / _channels;
            }
            return read;
        }
    }
}
