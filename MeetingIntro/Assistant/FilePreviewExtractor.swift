import Foundation
import PDFKit

/// Extracts file metadata + a short content preview for LLM classification (Issue #17).
/// Text-like files → first 2 KB + last 2 KB; PDFs → first page (PDFKit); everything else
/// → metadata only. Kept deliberately shallow (no OCR) — that's a later add-on.
enum FilePreviewExtractor {

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml",
        "html", "htm", "log", "swift", "py", "js", "ts", "java", "c", "cpp", "h",
        "rb", "go", "rs", "sh", "css", "sql", "ini", "conf", "srt", "vtt",
    ]
    private static let chunk = 2_048

    static func extract(_ url: URL) -> FilePreview {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate

        var preview: String? = nil
        if ext == "pdf" {
            preview = pdfFirstPage(url)
        } else if textExtensions.contains(ext) {
            preview = headTail(url)
        }
        return FilePreview(url: url, name: name, ext: ext, sizeBytes: size, modified: modified, contentPreview: preview)
    }

    /// First 2 KB + last 2 KB of a text file (whole file if small), UTF-8 lossy.
    private static func headTail(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        let text: String
        if data.count <= chunk * 2 {
            text = decode(data)
        } else {
            let head = decode(data.prefix(chunk))
            let tail = decode(data.suffix(chunk))
            text = head + "\n…\n" + tail
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func pdfFirstPage(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0),
              let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(chunk))
    }

    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
