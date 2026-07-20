import Foundation
import PDFKit
import Vision
import CoreGraphics

/// Extracts file metadata + a short content preview for LLM classification (Issue #17).
/// Text-like files → first 2 KB + last 2 KB; PDFs → first page (PDFKit, OCR fallback for
/// scans); images → on-device Vision OCR (v2.14.0); everything else → metadata only.
enum FilePreviewExtractor {

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml",
        "html", "htm", "log", "swift", "py", "js", "ts", "java", "c", "cpp", "h",
        "rb", "go", "rs", "sh", "css", "sql", "ini", "conf", "srt", "vtt",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
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
            preview = pdfFirstPage(url) ?? ocrPDFFirstPage(url)
        } else if textExtensions.contains(ext) {
            preview = headTail(url)
        } else if imageExtensions.contains(ext) {
            preview = ocrImage(url)
        }
        return FilePreview(url: url, name: name, ext: ext, sizeBytes: size, modified: modified, contentPreview: preview)
    }

    // MARK: - On-device OCR (Vision)

    /// Recognize text in an image file (screenshots, receipts, scans). Local + private.
    private static func ocrImage(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return recognizeText(in: cg)
    }

    /// OCR a scanned PDF's first page (used when it has no text layer).
    private static func ocrPDFFirstPage(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return recognizeText(in: cg)
    }

    private static func recognizeText(in cg: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(chunk))
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
