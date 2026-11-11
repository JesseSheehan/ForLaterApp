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
    @Guide(description: "A short title, under 8 words, naming the thing the person wants to come back to.")
    var title: String

    @Guide(description: "Exactly one category name, copied from the list of categories provided.")
    var category: String

    @Guide(description: "One or two short sentences of useful detail such as a date, place, price or who it is for. Empty if nothing useful.")
    var notes: String
}

enum ScreenshotAnalyzer {

    /// Reads a screenshot (and an optional shared link) and suggests card fields.
    /// Steps: Vision reads the text, a data detector finds links, then Apple's
    /// on-device model writes a title, picks a category and adds notes.
    /// Without Apple Intelligence it still returns the text and link.
    static func analyze(imageData: Data?, sharedLink: String?, categoryNames: [String]) async -> AnalysisResult {
        var result = AnalysisResult()

        let text: String
        if let imageData {
            text = await recognizeText(in: imageData)
        } else {
            text = ""
        }

        if let sharedLink, !sharedLink.isEmpty {
            result.link = sharedLink
        } else {
            result.link = firstLink(in: text)?.absoluteString
        }

        if let summary = await summarize(text: text, link: result.link, categoryNames: categoryNames) {
            result.title = summary.title
            result.categoryName = matchCategory(summary.category, in: categoryNames)
            result.notes = summary.notes
            result.usedLanguageModel = true
        } else {
            // Fallback: first line of text as the title, category Other.
            result.title = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.count > 3 })
                .map { String($0.prefix(60)) } ?? ""
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

    // MARK: - Steps

    static var isLanguageModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    private static func summarize(text: String, link: String?, categoryNames: [String]) async -> ScreenshotSummary? {
        guard isLanguageModelAvailable, !(text.isEmpty && (link ?? "").isEmpty) else { return nil }

        let instructions = """
        You help someone save things from screenshots so they can come back to them later. \
        Given the text read from a screenshot, write a short title for what they want to come back to, \
        choose the single best category from the list provided, and add brief helpful notes. \
        Use Events for anything with a date or time to attend. Use Content for articles, videos, posts, \
        products or things to read or watch. Use Other when nothing else fits.
        """
        let session = LanguageModelSession(instructions: instructions)

        // The on-device model has a small context window, so keep the text short.
        let prompt = """
        Categories: \(categoryNames.joined(separator: ", "))
        Link: \(link ?? "none")
        Text from the screenshot:
        \(text.prefix(2500))
        """

        // TODO(iOS 27): also attach the image itself to the prompt once we confirm
        // the exact multimodal API name in the iOS 27 SDK. Text alone works on iOS 26+.
        do {
            let response = try await session.respond(to: prompt, generating: ScreenshotSummary.self)
            return response.content
        } catch {
            print("For Later: language model failed: \(error)")
            return nil
        }
    }

    static func recognizeText(in imageData: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
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
