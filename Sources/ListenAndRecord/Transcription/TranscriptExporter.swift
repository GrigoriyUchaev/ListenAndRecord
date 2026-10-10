import Foundation

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case txt, docx

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String {
        switch self {
        case .txt: return "TXT — простой текст"
        case .docx: return "DOCX — документ Word"
        }
    }
}

enum TranscriptExporter {
    static func data(for transcript: Transcript, format: TranscriptFormat, timestamps: Bool) -> Data {
        switch format {
        case .txt: return Data(plainText(transcript, timestamps: timestamps).utf8)
        case .docx: return docx(transcript, timestamps: timestamps)
        }
    }

    static func header(_ t: Transcript) -> [String] {
        [
            "Файл: \(t.sourceName)",
            "Дата расшифровки: \(TimeFormat.longDate(t.createdAt))",
            "Длительность: \(TimeFormat.clock(t.duration))",
        ]
    }

    static func plainText(_ t: Transcript, timestamps: Bool) -> String {
        var lines = ["Расшифровка разговора"] + header(t) + [""]
        for p in t.paragraphs() {
            lines.append(timestamps ? "[\(TimeFormat.clock(p.start))] \(p.text)" : p.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - DOCX

    static func docx(_ t: Transcript, timestamps: Bool) -> Data {
        var body = paragraph("Расшифровка разговора", style: "Title")
        for line in header(t) { body += paragraph(line, style: "Meta") }
        body += paragraph("", style: nil)
        for p in t.paragraphs() {
            var runs = ""
            if timestamps {
                runs += "<w:r><w:rPr><w:color w:val=\"808080\"/></w:rPr><w:t xml:space=\"preserve\">[\(TimeFormat.clock(p.start))] </w:t></w:r>"
            }
            runs += "<w:r><w:t xml:space=\"preserve\">\(escape(p.text))</w:t></w:r>"
            body += "<w:p>\(runs)</w:p>"
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """

        let created = ISO8601DateFormatter().string(from: t.createdAt)
        var zip = ZipArchive(date: t.createdAt)
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(escape("Расшифровка — " + t.sourceName))</dc:title><dc:creator>ListenAndRecord</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(created)</dcterms:created></cp:coreProperties>
        """)
        zip.add("docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>ListenAndRecord</Application></Properties>
        """)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles)
        zip.add("word/_rels/document.xml.rels", documentRels)
        return zip.archive()
    }

    private static func paragraph(_ text: String, style: String?) -> String {
        let pPr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        let run = text.isEmpty ? "" : "<w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
        return "<w:p>\(pPr)\(run)</w:p>"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out += " "
            default:
                // XML 1.0 forbids most control characters.
                if scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    private static let documentRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="ru-RU"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:customStyle="1" w:styleId="Meta"><w:name w:val="Meta"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40"/></w:pPr><w:rPr><w:color w:val="666666"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style></w:styles>
    """
}
