import Foundation

public struct ClipAnalysis: Sendable {
    public var kind: ClipKind
    public var preview: String
    public var searchText: String
    public var charCount: Int
    public var dedupeKey: Data
    public var meta: ClipMeta
}

/// Classifies a captured pasteboard payload the way Raycast does (text / link / image / file / color).
public enum ClipAnalyzer {
    public static let previewLength = 2_000
    public static let searchLength = 200_000

    public static func analyze(payload: ClipPayload, string: String?, fileURLs: [URL]) -> ClipAnalysis {
        let types = Array(Set(payload.items.flatMap { $0.map(\.type) })).sorted()
        var meta = ClipMeta(types: types)

        if !fileURLs.isEmpty {
            let paths = fileURLs.map(\.path)
            meta.filePaths = paths
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let joined = paths.joined(separator: "\n")
            return ClipAnalysis(
                kind: .file,
                preview: joined,
                searchText: (names + paths).joined(separator: "\n").lowercased(),
                charCount: joined.count,
                dedupeKey: Data(("file:" + joined).utf8),
                meta: meta
            )
        }

        if let string, !string.isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            var kind = ClipKind.text
            if let hex = colorHex(trimmed) {
                kind = .color
                meta.colorHex = hex
            } else if isLink(trimmed) {
                kind = .link
                meta.url = trimmed
            }
            let utf16Count = string.utf16.count
            meta.wordCount = wordCount(string)
            return ClipAnalysis(
                kind: kind,
                preview: String(string.prefix(previewLength)),
                searchText: String(string.prefix(searchLength)).lowercased(),
                charCount: utf16Count < 5_000_000 ? string.count : utf16Count,
                dedupeKey: Data(("text:" + string).utf8),
                meta: meta
            )
        }

        if let image = payload.firstData(ofTypes: PasteboardMarkers.imageTypes) {
            var key = Data("image:".utf8)
            key.append(image.data)
            return ClipAnalysis(kind: .image, preview: "Image", searchText: "image", charCount: 0, dedupeKey: key, meta: meta)
        }

        if payload.firstData(ofTypes: [PasteboardMarkers.color]) != nil {
            var key = Data("color:".utf8)
            for item in payload.items { for rep in item { key.append(rep.data) } }
            return ClipAnalysis(kind: .color, preview: "Color", searchText: "color", charCount: 0, dedupeKey: key, meta: meta)
        }

        var key = Data("other:".utf8)
        for item in payload.items {
            for rep in item {
                key.append(Data(rep.type.utf8))
                key.append(rep.data)
            }
        }
        let preview = types.first ?? "Clipboard item"
        return ClipAnalysis(kind: .other, preview: preview, searchText: types.joined(separator: " ").lowercased(),
                            charCount: 0, dedupeKey: key, meta: meta)
    }

    static func isLink(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 4_096, !s.contains(where: { $0.isWhitespace }) else { return false }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false
        case "mailto", "ftp", "sftp", "ssh", "file", "tel":
            return true
        default:
            return s.contains("://") && scheme.count > 1
        }
    }

    /// Recognises #RGB, #RRGGBB, #RRGGBBAA.
    static func colorHex(_ s: String) -> String? {
        guard s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex.uppercased()
    }

    static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
