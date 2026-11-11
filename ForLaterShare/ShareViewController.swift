import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Whether the AI is still reading the screenshot, shown on the card.
@Observable
final class ShareCardState {
    var isAnalyzing = true
}

/// The share extension. It saves the shared screenshot or link right away, so
/// nothing is lost, then shows the For Later card while the AI fills it in.
/// If the AI can't finish here, the item stays marked and the app finishes it.
final class ShareViewController: UIViewController {
    private let container = DataStore.shared
    private let state = ShareCardState()
    private var item: ForLaterItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor in await start() }
    }

    @MainActor
    private func start() async {
        let (imageData, url, text) = await loadAttachments()
        let context = container.mainContext
        DataStore.seedIfNeeded(context)

        let newItem = ForLaterItem(
            screenshot: imageData.map(ScreenshotAnalyzer.preparedImageData(from:)),
            link: url?.absoluteString ?? ""
        )
        newItem.needsAnalysis = true
        newItem.sharedText = text ?? ""
        context.insert(newItem)
        try? context.save()
        item = newItem

        showCard(for: newItem)

        // A link with no picture (like an Instagram post): fetch its preview
        // (author, caption, image) while the card is already showing.
        if newItem.screenshot == nil {
            await ScreenshotAnalyzer.enrichFromLink(newItem)
            try? context.save()
        }

        let categories = (try? context.fetch(FetchDescriptor<ForLaterCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let result = await ScreenshotAnalyzer.analyze(
            imageData: newItem.screenshot,
            sharedLink: url?.absoluteString,
            sharedText: newItem.sharedText,
            categoryNames: categories.map(\.name),
            hometown: DataStore.settings(in: context).hometown
        )
        ScreenshotAnalyzer.apply(result, to: newItem, categories: categories)
        try? context.save()
        state.isAnalyzing = false
    }

    @MainActor
    private func showCard(for item: ForLaterItem) {
        let card = NavigationStack {
            ShareCard(item: item, state: state, onCancel: { [weak self] in self?.cancel() }, onDone: { [weak self] in self?.finish() })
        }
        .modelContainer(container)

        let host = UIHostingController(rootView: card)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    @MainActor
    private func finish() {
        try? container.mainContext.save()
        Task { @MainActor in
            await NotificationScheduler.reschedule(in: container.mainContext)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @MainActor
    private func cancel() {
        if let item {
            container.mainContext.delete(item)
            try? container.mainContext.save()
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    // MARK: - Reading what was shared

    private func loadAttachments() async -> (Data?, URL?, String?) {
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = inputItems.flatMap { $0.attachments ?? [] }
        var imageData: Data?
        var url: URL?
        var texts: [String] = []
        for provider in providers {
            if imageData == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                imageData = await loadImage(from: provider)
            } else if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                url = await loadURL(from: provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadText(from: provider) {
                texts.append(text)
            }
        }
        // Some apps also put a caption or title on the shared item itself.
        for inputItem in inputItems {
            if let content = inputItem.attributedContentText?.string, !content.isEmpty { texts.append(content) }
            if let title = inputItem.attributedTitle?.string, !title.isEmpty { texts.append(title) }
        }
        // Drop text that is just the link again.
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != url?.absoluteString }
        let text = cleaned.isEmpty ? nil : Array(NSOrderedSet(array: cleaned)).compactMap { $0 as? String }.joined(separator: "\n")
        // Text that is only a link counts as the link.
        if url == nil, let only = text, let detected = ScreenshotAnalyzer.firstLink(in: only), detected.absoluteString == only {
            return (imageData, detected, nil)
        }
        return (imageData, url, text)
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    private func loadImage(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                switch item {
                case let data as Data:
                    continuation.resume(returning: data)
                case let image as UIImage:
                    continuation.resume(returning: image.pngData())
                case let fileURL as URL:
                    continuation.resume(returning: try? Data(contentsOf: fileURL))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }
}

private struct ShareCard: View {
    @Bindable var item: ForLaterItem
    var state: ShareCardState
    var onCancel: () -> Void
    var onDone: () -> Void

    var body: some View {
        ForLaterCardView(item: item, isAnalyzing: state.isAnalyzing, onCancel: onCancel, onDone: onDone)
    }
}
