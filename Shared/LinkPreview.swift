import Foundation
import LinkPresentation
import UniformTypeIdentifiers

/// The public preview of a shared link: its title, description and image.
/// For an Instagram post this is usually the author, the caption and the
/// post's photo. Private posts, or sites that block previews, return less.
struct LinkPreview {
    var title: String?
    var summary: String?
    var imageData: Data?

    /// Title and description together, for the AI and for saving on the item.
    var text: String {
        [title, summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { lines, line in
                if !lines.contains(line) { lines.append(line) }
            }
            .joined(separator: "\n")
    }

    var isEmpty: Bool { text.isEmpty && imageData == nil }

    @MainActor
    static func fetch(for url: URL) async -> LinkPreview {
        var preview = LinkPreview()

        let provider = LPMetadataProvider()
        provider.timeout = 8
        if let metadata = try? await provider.startFetchingMetadata(for: url) {
            preview.title = metadata.title
            if let imageProvider = metadata.imageProvider {
                preview.imageData = await loadImage(from: imageProvider)
            }
        }

        // The page's description (an Instagram caption, for example) isn't part of
        // LinkPresentation's metadata, so read it from the page's meta tags.
        preview.summary = await fetchDescription(from: url)
        return preview
    }

    private static func loadImage(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func fetchDescription(from url: URL) async -> String? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 6)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(500_000), encoding: .utf8) else { return nil }
        let description = metaContent(in: html, key: "og:description")
            ?? metaContent(in: html, key: "description")
        return description.map(decodeEntities)
    }

    /// Finds <meta property|name="key" content="..."> in either attribute order.
    private static func metaContent(in html: String, key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(escapedKey)[\"'][^>]*?content\\s*=\\s*\"([^\"]*)\"",
            "<meta[^>]+content\\s*=\\s*\"([^\"]*)\"[^>]*?(?:property|name)\\s*=\\s*[\"']\(escapedKey)[\"']",
        ]
        let range = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, options: [], range: range),
                  let contentRange = Range(match.range(at: 1), in: html) else { continue }
            let content = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return content }
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&amp;": "&"]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities like &#x1F600; or &#8217;
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result),
                  let hexFlag = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result) else { continue }
            let radix = result[hexFlag].isEmpty ? 10 : 16
            if let code = UInt32(result[digits], radix: radix), let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }
}
