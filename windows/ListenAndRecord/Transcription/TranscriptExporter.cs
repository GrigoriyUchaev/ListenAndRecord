using System.IO;
using System.IO.Compression;
using System.Security;
using System.Text;

namespace ListenAndRecord.Transcription;

public static class TranscriptExporter
{
    public static void Save(Transcript t, string path, bool docx, bool timestamps)
    {
        if (docx) File.WriteAllBytes(path, Docx(t, timestamps));
        else File.WriteAllText(path, PlainText(t, timestamps), new UTF8Encoding(true));
    }

    private static IEnumerable<string> Header(Transcript t) =>
    [
        $"Файл: {t.SourceName}",
        $"Дата расшифровки: {TimeFormat.LongDate(t.CreatedAt)}",
        $"Длительность: {TimeFormat.Clock(t.Duration)}",
    ];

    public static string PlainText(Transcript t, bool timestamps)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Расшифровка разговора");
        foreach (var line in Header(t)) sb.AppendLine(line);
        sb.AppendLine();
        foreach (var p in t.Paragraphs())
        {
            sb.AppendLine(timestamps ? $"[{TimeFormat.Clock(p.Start)}] {p.Text}" : p.Text);
            sb.AppendLine();
        }
        return sb.ToString().Replace("\n", "\r\n").Replace("\r\r\n", "\r\n");
    }

    public static byte[] Docx(Transcript t, bool timestamps)
    {
        var body = new StringBuilder();
        body.Append(Paragraph("Расшифровка разговора", "Title"));
        foreach (var line in Header(t)) body.Append(Paragraph(line, "Meta"));
        body.Append("<w:p/>");
        foreach (var p in t.Paragraphs())
        {
            body.Append("<w:p>");
            if (timestamps)
                body.Append($"<w:r><w:rPr><w:color w:val=\"808080\"/></w:rPr><w:t xml:space=\"preserve\">[{TimeFormat.Clock(p.Start)}] </w:t></w:r>");
            body.Append($"<w:r><w:t xml:space=\"preserve\">{Escape(p.Text)}</w:t></w:r></w:p>");
        }

        var document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body +
            "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"850\" w:bottom=\"1134\" w:left=\"1701\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>";

        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
        {
            void Add(string name, string content)
            {
                var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
                using var w = new StreamWriter(entry.Open(), new UTF8Encoding(false));
                w.Write(content);
            }
            Add("[Content_Types].xml", ContentTypes);
            Add("_rels/.rels", RootRels);
            Add("docProps/core.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
                $"<dc:title>{Escape("Расшифровка — " + t.SourceName)}</dc:title><dc:creator>ListenAndRecord</dc:creator>" +
                $"<dcterms:created xsi:type=\"dcterms:W3CDTF\">{t.CreatedAt.ToUniversalTime():yyyy-MM-ddTHH:mm:ssZ}</dcterms:created></cp:coreProperties>");
            Add("docProps/app.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>ListenAndRecord</Application></Properties>");
            Add("word/document.xml", document);
            Add("word/styles.xml", Styles);
            Add("word/_rels/document.xml.rels", DocumentRels);
        }
        return ms.ToArray();
    }

    private static string Paragraph(string text, string style) =>
        $"<w:p><w:pPr><w:pStyle w:val=\"{style}\"/></w:pPr><w:r><w:t xml:space=\"preserve\">{Escape(text)}</w:t></w:r></w:p>";

    public static string Escape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if (c == '\t' || c == '\n' || c == '\r') { sb.Append(' '); continue; }
            if (c < 0x20 || c == '￾' || c == '￿') continue;
            sb.Append(c);
        }
        return SecurityElement.Escape(sb.ToString()) ?? "";
    }

    private const string ContentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>";

    private const string RootRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>";

    private const string DocumentRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>";

    private const string Styles =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"ru-RU\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"240\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"36\"/><w:szCs w:val=\"36\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"Meta\"><w:name w:val=\"Meta\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"40\"/></w:pPr><w:rPr><w:color w:val=\"666666\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:style></w:styles>";
}
