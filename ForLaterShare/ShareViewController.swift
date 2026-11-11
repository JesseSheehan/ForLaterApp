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
        let (imageData, url) = await loadAttachments()
        let context = container.mainContext
        DataStore.seedIfNeeded(context)

        let newItem = ForLaterItem(
            screenshot: imageData.map(ScreenshotAnalyzer.preparedImageData(from:)),
            link: url?.absoluteString ?? ""
        )
        newItem.needsAnalysis = true
        context.insert(newItem)
        try? context.save()
        item = newItem

        showCard(for: newItem)

        let categories = (try? context.fetch(FetchDescriptor<ForLaterCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let result = await ScreenshotAnalyzer.analyze(
            imageData: newItem.screenshot,
            sharedLink: url?.absoluteString,
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
        extensionContext?.completeRequest(returningItems: nil)
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

    private func loadAttachments() async -> (Data?, URL?) {
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = inputItems.flatMap { $0.attachments ?? [] }
        var imageData: Data?
        var url: URL?
        for provider in providers {
            if imageData == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                imageData = await loadImage(from: provider)
            } else if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                url = await loadURL(from: provider)
            }
        }
        return (imageData, url)
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
