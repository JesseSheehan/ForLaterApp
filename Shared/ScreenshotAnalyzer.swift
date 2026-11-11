import Foundation
import SwiftData
import UIKit
import Vision
import FoundationModels

/// What the AI suggests for a new For Later. Every field is a suggestion the
/// user can edit on the card.
struct AnalysisResult {
    var title: String = ""
    var categoryName: String?
    var link: String?
    var notes: String = ""
    var usedLanguageModel = false
}

/// The structured answer we ask Apple's on-device model for.
@Generable
struct ScreenshotSummary {
    @Guide(description: "A short, specific title under 10 words. Always include the names that matter: the band or artist, product, brand, dish, person, place or event. For example 'Tame Impala tour, Chicago Mar 14' or 'Italian sub from Gino's', never just 'Tour dates' or 'Picture'.")
    var title: String

    @Guide(description: "Exactly one category name, copied from the list of categories provided.")
    var category: String

    @Guide(description: "One or two short sentences with the useful details: what the image shows, plus any date, time, venue, price or who it is for. For a list of event dates, give the date and venue closest to the person's location. Empty if nothing useful.")
    var notes: String
}

/// What Vision finds in a screenshot before the language model sees it.
private struct VisionFindings {
    var text = ""
    /// Things Vision recognizes in a photo, like "sandwich" or "concert".
    var labels: [String] = []
}

enum ScreenshotAnalyzer {

    /// Reads a screenshot (and an optional shared link) and suggests card fields.
    /// Steps: Vision reads the text and recognizes objects, a data detector finds
    /// links, then Apple's on-device model looks at the image itself (iOS 27+)
    /// together with that text, writes a title, picks a category and adds notes.
    /// Without Apple Intelligence it still returns the text and link.
    static func analyze(imageData: Data?, sharedLink: String?, categoryNames: [String]) async -> AnalysisResult {
        var result = AnalysisResult()

        let findings: VisionFindings
        if let imageData {
            findings = await runVision(on: imageData)
        } else {
            findings = VisionFindings()
        }

        if let sharedLink, !sharedLink.isEmpty {
            result.link = sharedLink
        } else {
            result.link = firstLink(in: findings.text)?.absoluteString
        }

        if let summary = await summarize(findings: findings, imageData: imageData, link: result.link, categoryNames: categoryNames) {
            result.title = summary.title
            result.categoryName = matchCategory(summary.category, in: categoryNames)
            result.notes = summary.notes
            result.usedLanguageModel = true
        } else {
            // Fallback: first line of text (or what Vision saw) as the title, category Other.
            let firstLine = findings.text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.count > 3 })
                .map { String($0.prefix(60)) }
            result.title = firstLine ?? findings.labels.first?.capitalized ?? ""
            result.categoryName = categoryNames.first(where: { $0 == "Other" })
        }
        return result
    }

    /// Fills only the fields the user hasn't typed into yet.
    @MainActor
    static func apply(_ result: AnalysisResult, to item: ForLaterItem, categories: [ForLaterCategory]) {
        if item.title.isEmpty { item.title = result.title }
        if item.link.isEmpty, let link = result.link { item.link = link }
        if item.notes.isEmpty { item.notes = result.notes }
        if item.category == nil || item.category?.name == "Other",
           let name = result.categoryName,
           let match = categories.first(where: { $0.name == name }) {
            item.category = match
        }
        item.needsAnalysis = false
    }

    /// Analyzes every item that was saved before the AI got to it.
    @MainActor
    static func processPending(in context: ModelContext) async {
        let descriptor = FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.needsAnalysis == true })
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }
        let categories = (try? context.fetch(FetchDescriptor<ForLaterCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let names = categories.map(\.name)
        for item in pending {
            let result = await analyze(imageData: item.screenshot, sharedLink: item.link, categoryNames: names)
            apply(result, to: item, categories: categories)
        }
        try? context.save()
    }

    // MARK: - Language model

    static var isLanguageModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    private static let instructions = """
    You help someone save things from screenshots so they can come back to them later. \
    You get the screenshot and the text read from it. Work out what the person most likely \
    wants to come back to, and describe it specifically, with names. If the screenshot is a \
    photo with little or no text, say what it shows. Choose the single best category from the \
    list provided. Use Events for anything with a date or time to attend. Use Content for \
    articles, videos, posts, products or things to read, watch or buy. Use Other when nothing \
    else fits. If there are several dates or places, pick the one closest to the person's location.
    """

    private static func summarize(findings: VisionFindings, imageData: Data?, link: String?, categoryNames: [String]) async -> ScreenshotSummary? {
        guard isLanguageModelAvailable else { return nil }

        let prompt = makePrompt(findings: findings, link: link, categoryNames: categoryNames)

        // iOS 27+: let the model look at the image itself, not just its text.
        if #available(iOS 27.0, *), let imageData, let cgImage = modelImage(from: imageData) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(generating: ScreenshotSummary.self) {
                    prompt
                    Attachment(cgImage)
                }
                return response.content
            } catch {
                print("For Later: image prompt failed, retrying with text only: \(error)")
            }
        }

        // Text only (iOS 26, or if the image prompt failed).
        guard !(findings.text.isEmpty && findings.labels.isEmpty && (link ?? "").isEmpty) else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: ScreenshotSummary.self)
            return response.content
        } catch {
            print("For Later: language model failed: \(error)")
            return nil
        }
    }

    private static func makePrompt(findings: VisionFindings, link: String?, categoryNames: [String]) -> String {
        let now = Date()
        let region = Locale.current.region?.identifier ?? "unknown"
        // The on-device model has a small context window, so keep the text short.
        return """
        Today is \(now.formatted(date: .complete, time: .omitted)).
        The person's time zone is \(TimeZone.current.identifier) (country/region: \(region)). Use this as their location.
        Categories: \(categoryNames.joined(separator: ", "))
        Link: \(link ?? "none")
        Things recognized in the image: \(findings.labels.isEmpty ? "none" : findings.labels.joined(separator: ", "))
        Text from the screenshot:
        \(findings.text.isEmpty ? "(no text)" : String(findings.text.prefix(2000)))
        """
    }

    /// A smaller copy of the image for the model, so it fits the context window.
    private static func modelImage(from data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1024
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image.cgImage }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.cgImage
    }

    // MARK: - Vision

    private static func runVision(on imageData: Data) async -> VisionFindings {
        await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let classifyRequest = VNClassifyImageRequest()

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try? handler.perform([textRequest, classifyRequest])

            var findings = VisionFindings()
            findings.text = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            findings.labels = (classifyRequest.results ?? [])
                .filter { $0.confidence > 0.3 }
                .prefix(6)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            return findings
        }.value
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private static func matchCategory(_ name: String, in names: [String]) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names.first(where: { $0.lowercased() == cleaned })
            ?? names.first(where: { cleaned.contains($0.lowercased()) })
            ?? names.first(where: { $0 == "Other" })
    }

    /// Shrinks big screenshots and stores them as JPEG to save space and sync time.
    static func preparedImageData(from data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 2000
        let longest = max(image.size.width, image.size.height)
        var output = image
        if longest > maxSide {
            let scale = maxSide / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            output = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return output.jpegData(compressionQuality: 0.85) ?? data
    }
}
