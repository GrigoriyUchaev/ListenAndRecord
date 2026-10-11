using System.IO;
using System.Net.Http;

namespace ListenAndRecord.Core;

public sealed record ModelInfo(string Id, string Title, int SizeMb, string Note)
{
    public string FileName => $"ggml-{Id}.bin";
    public Uri Url => new($"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}");
    public string SizeText => SizeMb >= 1000 ? $"{SizeMb / 1024.0:0.0} ГБ" : $"{SizeMb} МБ";
}

/// <summary>Downloads, imports and lists Whisper models. Everything is stored locally.</summary>
public static class ModelManager
{
    public static readonly IReadOnlyList<ModelInfo> Catalog =
    [
        new("large-v3-turbo-q5_0", "Large v3 Turbo (сжатая)", 574,
            "Лучший выбор для современных ПК (Ryzen 5, Core i5 8-го поколения и новее): высокая точность."),
        new("large-v3-turbo", "Large v3 Turbo", 1624, "Чуть точнее сжатой, но вдвое больше памяти."),
        new("large-v3-q5_0", "Large v3 (сжатая)", 1081, "Максимальная точность, в 3–4 раза медленнее Turbo."),
        new("medium-q5_0", "Medium (сжатая)", 539, "Хорошая точность, средняя скорость."),
        new("small", "Small", 488, "Для старых и слабых ПК (4 ГБ памяти, процессор без AVX2)."),
        new("base", "Base", 148, "Очень быстрая, точность низкая — только для пробы."),
    ];

    public const string VadFileName = "ggml-silero-v5.1.2.bin";
    public static readonly Uri VadUrl = new("https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin");

    public static string ModelsDir => Path.Combine(AppSettings.Folder, "Models");
    public static string VadPath => Path.Combine(ModelsDir, VadFileName);

    public static string PathFor(string fileName) => Path.Combine(ModelsDir, fileName);
    public static bool IsInstalled(ModelInfo m) => File.Exists(PathFor(m.FileName));
    public static bool VadInstalled => File.Exists(VadPath);

    /// <summary>All model files available locally (downloaded or imported).</summary>
    public static IReadOnlyList<string> InstalledFiles()
    {
        if (!Directory.Exists(ModelsDir)) return [];
        return Directory.GetFiles(ModelsDir, "*.bin")
            .Select(f => Path.GetFileName(f))
            .Where(n => n != null && !n.Contains("silero", StringComparison.OrdinalIgnoreCase))
            .Select(n => n!)
            .OrderBy(n => n)
            .ToList();
    }

    public static string TitleFor(string fileName) =>
        Catalog.FirstOrDefault(m => m.FileName == fileName)?.Title ?? fileName;

    public static async Task DownloadAsync(Uri url, string fileName, IProgress<double> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(ModelsDir);
        var dest = PathFor(fileName);
        var tmp = dest + ".part";
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ListenAndRecord/2.0");
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? -1;
        try
        {
            await using (var src = await response.Content.ReadAsStreamAsync(ct))
            await using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, true))
            {
                var buffer = new byte[1 << 20];
                long read = 0;
                int n;
                while ((n = await src.ReadAsync(buffer, ct)) > 0)
                {
                    await fs.WriteAsync(buffer.AsMemory(0, n), ct);
                    read += n;
                    if (total > 0) progress.Report((double)read / total);
                }
            }
            File.Move(tmp, dest, true);
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }

    /// <summary>Copies a model file chosen by the user into the Models folder.</summary>
    public static async Task<string> ImportAsync(string sourcePath)
    {
        Directory.CreateDirectory(ModelsDir);
        var name = Path.GetFileName(sourcePath);
        if (!name.StartsWith("ggml-", StringComparison.OrdinalIgnoreCase)) name = "ggml-" + name;
        var dest = PathFor(name);
        if (!string.Equals(Path.GetFullPath(sourcePath), Path.GetFullPath(dest), StringComparison.OrdinalIgnoreCase))
        {
            await using var src = File.OpenRead(sourcePath);
            await using var dst = File.Create(dest);
            await src.CopyToAsync(dst);
        }
        return name;
    }

    public static void Delete(string fileName)
    {
        try { File.Delete(PathFor(fileName)); } catch { }
    }
}
