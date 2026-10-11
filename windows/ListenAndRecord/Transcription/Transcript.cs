using System.Globalization;
using System.Text;

namespace ListenAndRecord.Transcription;

public sealed record TranscriptSegment(double Start, double End, string Text)
{
    public int WordCount => TranscriptCleaner.WordCount(Text);
}

public sealed class Transcript
{
    public required string SourceName { get; init; }
    public required double Duration { get; init; }
    public required string Language { get; init; }
    public DateTime CreatedAt { get; init; } = DateTime.Now;
    public required IReadOnlyList<TranscriptSegment> Segments { get; init; }

    public sealed record Paragraph(double Start, string Text);

    public int WordCount => Segments.Sum(s => s.WordCount);

    /// <summary>Groups segments into paragraphs: a new one starts after a pause or when it gets long.</summary>
    public List<Paragraph> Paragraphs(double pause = 2.0, int maxCharacters = 700)
    {
        var result = new List<Paragraph>();
        StringBuilder? current = null;
        double currentStart = 0, lastEnd = 0;
        foreach (var seg in Segments)
        {
            var text = seg.Text.Trim();
            if (text.Length == 0) continue;
            if (current != null)
            {
                bool longPause = seg.Start - lastEnd >= pause;
                bool tooLong = current.Length >= maxCharacters && EndsSentence(current);
                if (longPause || tooLong)
                {
                    result.Add(new Paragraph(currentStart, current.ToString()));
                    current = new StringBuilder(text);
                    currentStart = seg.Start;
                }
                else
                {
                    current.Append(' ').Append(text);
                }
            }
            else
            {
                current = new StringBuilder(text);
                currentStart = seg.Start;
            }
            lastEnd = Math.Max(lastEnd, seg.End);
        }
        if (current != null) result.Add(new Paragraph(currentStart, current.ToString()));
        return result;
    }

    public string PlainText => string.Join("\n\n", Paragraphs().Select(p => p.Text));

    private static bool EndsSentence(StringBuilder sb) => sb.Length > 0 && ".!?…".Contains(sb[^1]);
}

public static class TimeFormat
{
    public static string Clock(double seconds)
    {
        var total = Math.Max(0, (long)Math.Floor(seconds));
        return $"{total / 3600:00}:{total % 3600 / 60:00}:{total % 60:00}";
    }

    public static string Human(double seconds)
    {
        var total = Math.Max(0, (long)Math.Round(seconds));
        long h = total / 3600, m = total % 3600 / 60, s = total % 60;
        if (h > 0) return $"{h} ч {m} мин";
        if (m > 0) return $"{m} мин {s} с";
        return $"{s} с";
    }

    public static string FileStamp(DateTime? date = null) =>
        (date ?? DateTime.Now).ToString("yyyy-MM-dd HH-mm", CultureInfo.InvariantCulture);

    public static string LongDate(DateTime date) =>
        date.ToString("d MMMM yyyy, HH:mm", new CultureInfo("ru-RU"));
}

/// <summary>Removes typical Whisper artefacts: captions hallucinated in silence, loops, annotations.</summary>
public static class TranscriptCleaner
{
    private static readonly string[] HallucinationMarkers =
    [
        "субтитр", "dimatorzok", "amara.org", "продолжение следует", "спасибо за просмотр",
        "подписывайтесь на канал", "ставьте лайк", "редактор субтитров", "корректор а.",
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
    ];

    public static int WordCount(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(w => w.Any(char.IsLetterOrDigit));

    public static string Normalized(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var c in text.ToLowerInvariant()) sb.Append(char.IsLetterOrDigit(c) || c == '.' ? c : ' ');
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    public static bool IsAnnotationOnly(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) return true;
        if ("[(*♪".Contains(t[0]) && "])*♪".Contains(t[^1])) return true;
        return !t.Any(char.IsLetterOrDigit);
    }

    public static bool IsHallucination(string text)
    {
        if (WordCount(text) > 14) return false;
        var n = Normalized(text);
        return HallucinationMarkers.Any(n.Contains);
    }

    /// <param name="collapseLoops">Drop a phrase repeated 3+ times back to back. Only safe within one
    /// Whisper call: across chunks the same words can legitimately recur (e.g. "Да." … "Да.").</param>
    public static List<TranscriptSegment> Clean(IEnumerable<TranscriptSegment> segments, bool collapseLoops = true)
    {
        var output = new List<TranscriptSegment>();
        int repeat = 0;
        foreach (var s in segments)
        {
            var seg = s with { Text = s.Text.Trim() };
            if (seg.Text.Length == 0 || IsAnnotationOnly(seg.Text) || IsHallucination(seg.Text)) continue;
            if (collapseLoops && output.Count > 0 && seg.Start - output[^1].End < 1.5 &&
                Normalized(output[^1].Text) == Normalized(seg.Text))
            {
                repeat++;
                // A phrase repeated 3+ times in a row is a decoding loop, not speech.
                if (repeat >= 2)
                {
                    output[^1] = output[^1] with { End = Math.Max(output[^1].End, seg.End) };
                    continue;
                }
            }
            else
            {
                repeat = 0;
            }
            output.Add(seg);
        }
        return output;
    }
}
