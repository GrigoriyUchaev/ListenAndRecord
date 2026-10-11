using System.IO;
using System.Text.Json;

namespace ListenAndRecord.Core;

/// <summary>User settings, stored as JSON in %LOCALAPPDATA%\ListenAndRecord.</summary>
public sealed class AppSettings
{
    public bool CaptureMicrophone { get; set; } = true;
    public bool CaptureSystemAudio { get; set; } = true;
    public string AudioFormat { get; set; } = "m4a";
    public string? LastSaveDirectory { get; set; }

    public string SelectedModel { get; set; } = "";      // file name inside the Models folder
    public string Language { get; set; } = "ru";
    public string TranscriptFormat { get; set; } = "docx";
    public bool IncludeTimestamps { get; set; } = true;
    public bool UseVad { get; set; } = true;
    public bool RecoverGaps { get; set; } = true;
    public bool? HighAccuracy { get; set; }               // null = choose by hardware

    public static string Folder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ListenAndRecord");

    private static string FilePath => Path.Combine(Folder, "settings.json");

    public static AppSettings Current { get; } = Load();

    public bool EffectiveHighAccuracy => HighAccuracy ?? Hardware.RecommendedHighAccuracy;

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch { /* corrupted settings: start fresh */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* not critical */ }
    }
}
