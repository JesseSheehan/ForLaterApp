import SwiftUI
import SwiftData

/// Settings > Privacy: location (hometown or current city) and how much AI to use.
struct PrivacyView: View {
    @Environment(\.modelContext) private var context
    @State private var settings: AppSettings?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your privacy is important to us.", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text("For Later has no accounts and no servers of its own. Your For Laters stay on your devices and in your own iCloud. You decide how much AI is used and where it runs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let settings {
                LocationSection(settings: settings)
                AIUsageSection(settings: settings)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if settings == nil {
                settings = DataStore.settings(in: context)
            }
        }
    }
}

// MARK: - Location

private struct LocationSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Bindable var settings: AppSettings
    @State private var isLocating = false
    @State private var locationDenied = false

    var body: some View {
        Section {
            TextField("Hometown, like Austin, TX", text: $settings.hometown)
                .textContentType(.addressCity)

            Toggle(isOn: locationBinding) {
                Label("Use my current location", systemImage: "location")
            }

            if settings.useLocation {
                if isLocating {
                    LabeledContent("Current city") { ProgressView() }
                } else if !settings.locationCity.isEmpty {
                    LabeledContent("Current city", value: settings.locationCity)
                }
            }

            if locationDenied {
                Button("Allow location in the Settings app") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Just entering a hometown saves battery and doesn't use GPS. Location is only used to make AI results fit you better, like picking the closest tour date, and only your city is kept.")
        }
    }

    private var locationBinding: Binding<Bool> {
        Binding(
            get: { settings.useLocation },
            set: { isOn in
                if isOn {
                    Task { await turnOnLocation() }
                } else {
                    settings.useLocation = false
                    settings.locationCity = ""
                    try? context.save()
                }
            }
        )
    }

    private func turnOnLocation() async {
        let status = await LocationProvider.shared.requestAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            locationDenied = true
            settings.useLocation = false
            return
        }
        locationDenied = false
        settings.useLocation = true
        isLocating = true
        if let city = await LocationProvider.shared.currentCity() {
            settings.locationCity = city
        }
        isLocating = false
        try? context.save()
    }
}

// MARK: - AI Usage

private struct AIUsageSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            ForEach(AIMode.allCases) { mode in
                Button {
                    settings.aiMode = mode
                    try? context.save()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mode.systemImage)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(mode.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                if mode == .onDevice {
                                    Text("Recommended")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(mode.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let note = availabilityNote(for: mode) {
                                Text(note)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                        if settings.aiMode == mode {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if settings.aiMode == .onDevice || settings.aiMode == .full {
                Toggle(isOn: $settings.aiAlwaysRefines) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Always polish with AI")
                        Text(settings.aiAlwaysRefines
                             ? "AI improves every card, like adding the band's name to a tour poster."
                             : "AI only steps in when text recognition can't find a title or category, or the screenshot is a photo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("AI Usage")
        } footer: {
            Text("Each level adds to the one before it: text recognition first, then on-device AI, then Private Cloud Compute only when needed. On-device AI is the best balance of privacy and results.")
        }
    }

    private func availabilityNote(for mode: AIMode) -> String? {
        switch mode {
        case .onDevice where !ScreenshotAnalyzer.isLanguageModelAvailable:
            return "On-device AI isn't available on this iPhone right now (it needs Apple Intelligence), so text recognition is used instead."
        case .full where !ScreenshotAnalyzer.isCloudModelAvailable:
            return "Private Cloud Compute isn't available right now, so on-device AI is used."
        default:
            return nil
        }
    }
}
