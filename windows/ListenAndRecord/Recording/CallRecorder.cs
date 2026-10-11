using System.IO;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using ListenAndRecord.Core;

namespace ListenAndRecord.Recording;

public enum RecorderState { Idle, Recording, Paused }

public sealed record FinishedRecording(string Directory, IReadOnlyList<string> Tracks, double Duration, DateTime StartedAt)
{
    public string? SavedTo { get; set; }
}

/// <summary>
/// Records a call: system sound via WASAPI loopback (everything the other participants say,
/// from any app — Zoom, Teams, Telegram, Discord, browser) plus the microphone.
/// </summary>
public sealed class CallRecorder
{
    private readonly RecordingClock _clock = new();
    private WasapiLoopbackCapture? _systemCapture;
    private WasapiCapture? _micCapture;
    private TrackWriter? _systemWriter, _micWriter;
    private string? _directory;
    private DateTime _startedAt;

    public RecorderState State { get; private set; } = RecorderState.Idle;
    public FinishedRecording? Finished { get; set; }
    public double Elapsed => State == RecorderState.Idle ? Finished?.Duration ?? 0 : _clock.Elapsed;
    public float MicLevel => State == RecorderState.Recording ? _micWriter?.Level ?? 0 : 0;
    public float SystemLevel => State == RecorderState.Recording ? _systemWriter?.Level ?? 0 : 0;
    public bool HasUnsaved => Finished != null && Finished.SavedTo == null;

    /// <summary>Raised (on a capture thread) when a device fails during recording.</summary>
    public event Action<string>? CaptureError;

    public static string RecordingsRoot => Path.Combine(AppSettings.Folder, "Recordings");

    public void Start(bool microphone, bool systemSound)
    {
        if (State != RecorderState.Idle) return;
        if (!microphone && !systemSound) throw new InvalidOperationException("Выберите хотя бы один источник: микрофон или звук созвона.");
        CleanupSaved();
        _startedAt = DateTime.Now;
        _directory = Path.Combine(RecordingsRoot, $"{TimeFormatStamp(_startedAt)} {Guid.NewGuid().ToString("N")[..6]}");
        Directory.CreateDirectory(_directory);
        _clock.Start();
        try
        {
            if (systemSound)
            {
                var writer = new TrackWriter(Path.Combine(_directory, "system.wav"), _clock);
                var capture = new WasapiLoopbackCapture();
                capture.DataAvailable += (_, e) => writer.Append(e.Buffer, e.BytesRecorded, capture.WaveFormat);
                capture.RecordingStopped += (_, e) => { if (e.Exception != null) CaptureError?.Invoke("Сбой записи звука созвона: " + e.Exception.Message); };
                capture.StartRecording();
                _systemWriter = writer;
                _systemCapture = capture;
            }
            if (microphone)
            {
                WasapiCapture capture;
                try { capture = new WasapiCapture(); }
                catch (Exception ex) { throw new InvalidOperationException("Микрофон не найден или недоступен: " + ex.Message, ex); }
                var writer = new TrackWriter(Path.Combine(_directory, "mic.wav"), _clock);
                capture.DataAvailable += (_, e) => writer.Append(e.Buffer, e.BytesRecorded, capture.WaveFormat);
                capture.RecordingStopped += (_, e) => { if (e.Exception != null) CaptureError?.Invoke("Сбой записи микрофона: " + e.Exception.Message); };
                capture.StartRecording();
                _micWriter = writer;
                _micCapture = capture;
            }
            Finished = null;
            State = RecorderState.Recording;
        }
        catch
        {
            StopDevices();
            try { Directory.Delete(_directory, true); } catch { }
            _systemWriter = _micWriter = null;
            throw;
        }
    }

    public void TogglePause()
    {
        if (State == RecorderState.Recording) { _clock.Pause(); State = RecorderState.Paused; }
        else if (State == RecorderState.Paused) { _clock.Resume(); State = RecorderState.Recording; }
    }

    public FinishedRecording? Stop()
    {
        if (State == RecorderState.Idle || _directory == null) return null;
        double duration = _clock.Elapsed;
        StopDevices();
        _systemWriter?.Finish(duration);
        _micWriter?.Finish(duration);
        var tracks = new[] { _systemWriter?.Path, _micWriter?.Path }.Where(p => p != null && File.Exists(p)).Select(p => p!).ToList();
        Finished = new FinishedRecording(_directory, tracks, duration, _startedAt);
        _systemWriter = _micWriter = null;
        State = RecorderState.Idle;
        return Finished;
    }

    public void Discard()
    {
        if (Finished == null) return;
        try { Directory.Delete(Finished.Directory, true); } catch { }
        Finished = null;
    }

    public void MarkSaved(string path)
    {
        if (Finished == null) return;
        Finished.SavedTo = path;
        try { File.WriteAllText(Path.Combine(Finished.Directory, ".saved"), path); } catch { }
    }

    private void StopDevices()
    {
        try { _systemCapture?.StopRecording(); } catch { }
        try { _micCapture?.StopRecording(); } catch { }
        _systemCapture?.Dispose();
        _micCapture?.Dispose();
        _systemCapture = null;
        _micCapture = null;
    }

    /// <summary>Removes recordings that were already saved (or are empty).</summary>
    private static void CleanupSaved()
    {
        if (!Directory.Exists(RecordingsRoot)) return;
        foreach (var dir in Directory.GetDirectories(RecordingsRoot))
        {
            bool saved = File.Exists(Path.Combine(dir, ".saved"));
            bool empty = !Directory.EnumerateFiles(dir, "*.wav").Any();
            if (saved || empty) { try { Directory.Delete(dir, true); } catch { } }
        }
    }

    /// <summary>After a crash or quit, offer the last unsaved recording again.</summary>
    public static FinishedRecording? FindUnsaved()
    {
        if (!Directory.Exists(RecordingsRoot)) return null;
        var dir = Directory.GetDirectories(RecordingsRoot)
            .Where(d => !File.Exists(Path.Combine(d, ".saved")) && Directory.EnumerateFiles(d, "*.wav").Any())
            .OrderByDescending(Directory.GetCreationTime)
            .FirstOrDefault();
        if (dir == null) return null;
        var tracks = new[] { "system.wav", "mic.wav" }.Select(n => Path.Combine(dir, n)).Where(File.Exists).ToList();
        double duration = 0;
        foreach (var t in tracks)
        {
            try { using var r = new WaveFileReader(t); duration = Math.Max(duration, r.TotalTime.TotalSeconds); }
            catch { }
        }
        return duration > 0.5 ? new FinishedRecording(dir, tracks, duration, Directory.GetCreationTime(dir)) : null;
    }

    private static string TimeFormatStamp(DateTime d) => Transcription.TimeFormat.FileStamp(d);
}
