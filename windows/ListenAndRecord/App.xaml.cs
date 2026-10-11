using System.IO;
using System.Windows;
using System.Windows.Threading;
using ListenAndRecord.Core;
using ListenAndRecord.Transcription;

namespace ListenAndRecord;

public partial class App : Application
{
    public static string LogPath => Path.Combine(AppSettings.Folder, "error.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandled;

        // Hidden mode used by CI: ListenAndRecord.exe --selftest <model> <audio> <output.txt>
        if (e.Args.Length >= 4 && e.Args[0] == "--selftest")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _ = RunSelfTest(e.Args[1], e.Args[2], e.Args[3]);
            return;
        }

        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    private async Task RunSelfTest(string model, string audio, string output)
    {
        int code = 0;
        try
        {
            var settings = new WhisperSettings(Path.GetFullPath(model), null, "en", Hardware.Threads, 5);
            var pipeline = new TranscriptionPipeline(settings, useVad: false, recoverGaps: true);
            var transcript = await pipeline.RunAsync(Path.GetFullPath(audio), _ => { }, CancellationToken.None);
            File.WriteAllText(output, $"CPU: {Hardware.Summary}\n" + TranscriptExporter.PlainText(transcript, true));
            TranscriptExporter.Save(transcript, Path.ChangeExtension(output, ".docx"), true, true);
            if (transcript.Segments.Count == 0) code = 2;
        }
        catch (Exception ex)
        {
            File.WriteAllText(output, "ERROR: " + ex);
            code = 1;
        }
        Shutdown(code);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            File.AppendAllText(LogPath, $"[{DateTime.Now}] {e.Exception}\n\n");
        }
        catch { }
        MessageBox.Show("Произошла ошибка:\n" + e.Exception.Message + $"\n\nПодробности: {LogPath}",
            "ListenAndRecord", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
