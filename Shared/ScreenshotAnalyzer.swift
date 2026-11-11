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
    /// For events: when it happens, as found in the screenshot.
    var dueDate: Date?
    var dueHasTime = false
    var engine: AnalysisEngine = .none
}

/// Everything the analyzer needs to know about the user's setup.
struct AnalysisContext {
    var categoryNames: [String] = []
    /// The user's names for the starter Events and Content categories, if they still exist.
    var eventsName: String?
    var contentName: String?
    /// Hometown or current city; empty if unknown.
    var location: String = ""
    var mode: AIMode = .onDevice
    var alwaysRefines = true

    @MainActor
    init(in context: ModelContext, categories: [ForLaterCategory]) {
        let settings = DataStore.settings(in: context)
        categoryNames = categories.map(\.name)
        eventsName = categories.first(where: { $0.isEvents })?.name
        contentName = categories.first(where: { $0.isContent })?.name
        location = settings.aiLocation
        mode = settings.aiMode
        alwaysRefines = settings.aiAlwaysRefines
    }
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

    @Guide(description: "If this is an event, the date it happens as yyyy-MM-dd, choosing the one closest to the person's location. Use the next upcoming year if no year is shown. Empty if not an event.")
    var eventDate: String

    @Guide(description: "If the event shows a start time, that time as 24-hour HH:mm. Empty otherwise.")
    var eventTime: String
}

/// What Vision finds in a screenshot before the language model sees it.
private struct VisionFindings {
    var text = ""
    /// Things Vision recognizes in a photo, like "sandwich" or "concert".
    var labels: [String] = []
}

enum ScreenshotAnalyzer {

    /// Reads a screenshot (and an optional shared link) and suggests card fields,
    /// using as much AI as the user allows. Each step builds on the one before:
    /// 1. Vision/OCR: reads text, links and dates and recognizes objects in photos.
    /// 2. On-device AI: writes a specific title, picks the category, adds notes.
    static func analyze(imageData: Data?, sharedLink: String?, sharedText: String? = nil, context: AnalysisContext) async -> AnalysisResult {
        guard context.mode != .manual else { return AnalysisResult() }

        // Step 1: Vision/OCR and data detectors.
        let findings: VisionFindings
        if let imageData {
            findings = await runVision(on: imageData)
        } else {
            findings = VisionFindings()
        }
        var result = visionResult(findings: findings, sharedLink: sharedLink, sharedText: sharedText, context: context)
        guard context.mode != .visionOnly else { return result }

        let needsAI = context.alwaysRefines || !isComplete(result, findings: findings)
        guard needsAI else { return result }

        // Step 2: on-device AI.
        if let summary = await summarize(findings: findings, imageData: imageData,
                                         link: result.link, sharedText: sharedText, context: context) {
            merge(summary, into: &result, categoryNames: context.categoryNames)
            result.engine = .onDevice
        }
        return result
    }

    /// Step 1 on its own: put what Vision and the data detectors found into the right fields.
    private static func visionResult(findings: VisionFindings, sharedLink: String?, sharedText: String?, context: AnalysisContext) -> AnalysisResult {
        var result = AnalysisResult()
        let allText = [sharedText ?? "", findings.text].filter { !$0.isEmpty }.joined(separator: "\n")

        if let sharedLink, !sharedLink.isEmpty {
            result.link = sharedLink
        } else {
            result.link = firstLink(in: allText)?.absoluteString
        }

        let lines = allText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.count > 3 && firstLink(in: line)?.absoluteString != line
            }
        if let first = lines.first {
            result.title = String(first.prefix(60))
            let rest = lines.dropFirst().prefix(2).joined(separator: " · ")
            result.notes = String(rest.prefix(160))
        } else if !findings.labels.isEmpty {
            result.title = findings.labels[0].capitalized
            result.notes = "Looks like: " + findings.labels.prefix(3).joined(separator: ", ")
        }

        if let due = firstUpcomingDate(in: allText) {
            result.dueDate = due.date
            result.dueHasTime = due.hasTime
        }

        // Simple category rules: a date means an event, a link or caption means content.
        if result.dueDate != nil, let events = context.eventsName {
            result.categoryName = events
        } else if result.link != nil || !(sharedText ?? "").isEmpty, let content = context.contentName {
            result.categoryName = content
        }

        result.engine = (findings.text.isEmpty && findings.labels.isEmpty && result.link == nil) ? .none : .vision
        return result
    }

    /// Whether text recognition alone gave a usable card.
    private static func isComplete(_ result: AnalysisResult, findings: VisionFindings) -> Bool {
        !result.title.isEmpty && result.categoryName != nil && findings.text.count >= 20
    }

    /// Lays the AI's answer over the Vision result, keeping Vision's fields where the AI left blanks.
    private static func merge(_ summary: ScreenshotSummary, into result: inout AnalysisResult, categoryNames: [String]) {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { result.title = title }
        if let category = matchCategory(summary.category, in: categoryNames) { result.categoryName = category }
        let notes = summary.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { result.notes = notes }
        if let due = parseEventDate(summary.eventDate, time: summary.eventTime) {
            result.dueDate = due.date
            result.dueHasTime = due.hasTime
        }
    }

    /// The first date in the text that hasn't passed, and whether it included a time.
    static func firstUpcomingDate(in text: String) -> (date: Date, hasTime: Bool)? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let cutoff = Date().addingTimeInterval(-86_400)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let date = match.date, date > cutoff, let matchRange = Range(match.range, in: text) else { continue }
            let snippet = text[matchRange].lowercased()
            let hasTime = snippet.contains(":") || snippet.contains("am") || snippet.contains("pm")
            return (hasTime ? date : Calendar.current.startOfDay(for: date), hasTime)
        }
        return nil
    }

    /// Fills in the card. Normally only fields the user hasn't typed into yet;
    /// with `overwrite` (the "Use AI to input details" button) it replaces them.
    @MainActor
    static func apply(_ result: AnalysisResult, to item: ForLaterItem, categories: [ForLaterCategory], overwrite: Bool = false) {
        if overwrite || item.title.isEmpty, !result.title.isEmpty { item.title = result.title }
        if item.link.isEmpty, let link = result.link { item.link = link }
        if overwrite || item.notes.isEmpty, !result.notes.isEmpty { item.notes = result.notes }
        if overwrite || item.category == nil || item.category?.isOther == true {
            if let name = result.categoryName, let match = categories.first(where: { $0.name == name }) {
                item.category = match
            } else if item.category == nil {
                item.category = categories.first(where: { $0.isOther })
            }
        }
        if item.dueDate == nil, item.category?.isEvents == true, let due = result.dueDate {
            item.dueDate = due
            item.dueHasTime = result.dueHasTime
            item.dueOptionRaw = DueOption.custom.rawValue
        }
        if result.engine != .none {
            item.analysisEngineRaw = result.engine.rawValue
        }
        item.needsAnalysis = false
    }

    /// For a shared link with no picture (an Instagram post, for example), fetches
    /// the link's public preview: its image becomes the item's picture and its
    /// title and caption are saved for the AI.
    @MainActor
    static func enrichFromLink(_ item: ForLaterItem) async {
        guard item.screenshot == nil, !item.link.isEmpty, let url = URL(string: item.link) else { return }
        let preview = await LinkPreview.fetch(for: url)
        if let imageData = preview.imageData {
            item.screenshot = preparedImageData(from: imageData)
        }
        // Keep any text the sharing app sent, and add the preview's.
        let previewText = preview.text
        if !previewText.isEmpty, !item.sharedText.contains(previewText) {
            item.sharedText = item.sharedText.isEmpty ? previewText : item.sharedText + "\n" + previewText
        }
    }

    /// Turns the model's "yyyy-MM-dd" and "HH:mm" strings into a date.
    private static func parseEventDate(_ dateText: String, time timeText: String) -> (date: Date, hasTime: Bool)? {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        guard let day = dayFormatter.date(from: dateText.trimmingCharacters(in: .whitespaces)) else { return nil }
        // Ignore dates more than a day in the past; the model guessed a wrong year.
        guard day > Date().addingTimeInterval(-86_400) else { return nil }

        let parts = timeText.trimmingCharacters(in: .whitespaces).split(separator: ":")
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
           (0..<24).contains(hour), (0..<60).contains(minute),
           let withTime = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
            return (withTime, true)
        }
        return (day, false)
    }

    /// Analyzes every item that was saved before the AI got to it.
    @MainActor
    static func processPending(in context: ModelContext) async {
        let descriptor = FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.needsAnalysis == true })
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }
        let categories = (try? context.fetch(FetchDescriptor<ForLaterCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let analysisContext = AnalysisContext(in: context, categories: categories)
        for item in pending {
            if analysisContext.mode == .manual {
                item.needsAnalysis = false
                continue
            }
            await enrichFromLink(item)
            let result = await analyze(imageData: item.screenshot, sharedLink: item.link, sharedText: item.sharedText,
                                       context: analysisContext)
            apply(result, to: item, categories: categories)
        }
        try? context.save()
    }

    // MARK: - Language model

    static var isLanguageModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    private static let instructions = """
    You help someone save things from screenshots and shared links so they can come back to them later. \
    You get the screenshot and the text read from it. Work out what the person most likely \
    wants to come back to, and describe it specifically, with names. If the screenshot is a \
    photo with little or no text, say what it shows. Choose the single best category from the \
    list provided, using the person's own category names exactly. Prefer a category for events \
    for anything with a date or time to attend, and a category for content for articles, videos, \
    posts, products or things to read, watch or buy. Use the catch-all category (usually Other) \
    when nothing else fits. If there are several dates or places, pick the one closest to the \
    person's location.
    """

    private static func summarize(findings: VisionFindings, imageData: Data?, link: String?, sharedText: String?, context: AnalysisContext) async -> ScreenshotSummary? {
        guard isLanguageModelAvailable else { return nil }
        let makeSession = { LanguageModelSession(instructions: instructions) }

        let prompt = makePrompt(findings: findings, link: link, sharedText: sharedText, context: context)

        // iOS 27+: let the model look at the image itself, not just its text.
        if #available(iOS 27.0, *), let imageData, let cgImage = modelImage(from: imageData) {
            do {
                let session = makeSession()
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
        guard !(findings.text.isEmpty && findings.labels.isEmpty && (link ?? "").isEmpty && (sharedText ?? "").isEmpty) else { return nil }
        do {
            let session = makeSession()
            let response = try await session.respond(to: prompt, generating: ScreenshotSummary.self)
            return response.content
        } catch {
            print("For Later: language model failed: \(error)")
            return nil
        }
    }

    private static func makePrompt(findings: VisionFindings, link: String?, sharedText: String?, context: AnalysisContext) -> String {
        let now = Date()
        let region = Locale.current.region?.identifier ?? "unknown"
        let town = context.location
        let location = town.isEmpty
            ? "The person's time zone is \(TimeZone.current.identifier) (country/region: \(region)). Use this as their location."
            : "The person lives in \(town) (time zone \(TimeZone.current.identifier)). Use this as their location."
        // The on-device model has a small context window, so keep the text short.
        return """
        Today is \(now.formatted(date: .complete, time: .omitted)).
        \(location)
        Categories: \(context.categoryNames.joined(separator: ", "))
        Link: \(link ?? "none")
        Shared with the link (title, author, caption): \((sharedText ?? "").isEmpty ? "none" : String((sharedText ?? "").prefix(800)))
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
