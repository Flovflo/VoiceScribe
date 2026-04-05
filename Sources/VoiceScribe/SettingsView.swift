import SwiftUI
import VoiceScribeCore

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @AppStorage("selectedModel") private var selectedModel = ASRModelCatalog.defaultModelID
    @AppStorage(ASRLanguageCatalog.defaultsKey) private var selectedLanguageID = ASRLanguageCatalog.defaultLanguageID
    @State private var showAdvancedModels = false

    private let systemDefaultMicrophoneTag = "__voicescribe_system_default__"

    private var selectedMicrophoneTag: Binding<String> {
        Binding(
            get: { appState.selectedInputDeviceUID ?? systemDefaultMicrophoneTag },
            set: { newValue in
                if newValue == systemDefaultMicrophoneTag {
                    appState.setPreferredInputDevice(uid: nil)
                } else {
                    appState.setPreferredInputDevice(uid: newValue)
                }
            }
        )
    }

    private var selectedModelLabel: String {
        if let option = ASRModelCatalog.supportedModels.first(where: { $0.id == selectedModel }) {
            return "\(option.title) • \(option.quantization)"
        }
        return selectedModel
    }

    var body: some View {
        Form {
            SpeechModelSection(
                selectedModel: $selectedModel,
                showAdvancedModels: $showAdvancedModels,
                selectedModelLabel: selectedModelLabel
            )

            TranscriptionLanguageSection(selectedLanguageID: $selectedLanguageID)

            MicrophoneSection(
                appState: appState,
                selectedMicrophoneTag: selectedMicrophoneTag,
                systemDefaultMicrophoneTag: systemDefaultMicrophoneTag
            )

            if AppDistribution.isAppStoreBuild {
                Section("Clipboard") {
                    Text("This App Store build copies each transcript to the clipboard. Paste manually with Command-V in the destination app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Engine Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(appState.status)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Text("VoiceScribe • Native MLX Qwen3-ASR")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(width: 470, height: 500)
        .onAppear {
            appState.refreshInputDevices()
            if !ASRModelCatalog.isSupportedASRModel(selectedModel) {
                selectedModel = ASRModelCatalog.defaultModelID
            }
            let normalizedLanguageID = ASRLanguageCatalog.normalizedLanguageID(selectedLanguageID)
            if normalizedLanguageID != selectedLanguageID {
                selectedLanguageID = normalizedLanguageID
            }
            appState.engine.setPreferredLanguage(
                ASRLanguageCatalog.modelLanguage(for: normalizedLanguageID)
            )
        }
        .onChange(of: selectedModel) { _, newValue in
            if !ASRModelCatalog.isSupportedASRModel(newValue) {
                selectedModel = ASRModelCatalog.defaultModelID
                return
            }
            appState.engine.setModel(newValue)
        }
        .onChange(of: selectedLanguageID) { _, newValue in
            let normalizedLanguageID = ASRLanguageCatalog.normalizedLanguageID(newValue)
            if normalizedLanguageID != newValue {
                selectedLanguageID = normalizedLanguageID
                return
            }
            appState.engine.setPreferredLanguage(
                ASRLanguageCatalog.modelLanguage(for: normalizedLanguageID)
            )
        }
    }
}

private struct SpeechModelSection: View {
    @Binding var selectedModel: String
    @Binding var showAdvancedModels: Bool
    let selectedModelLabel: String

    var body: some View {
        Section("Speech Model") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recommended")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    ForEach(ASRModelCatalog.quickChoices) { model in
                        Button(action: { selectedModel = model.id }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.title.replacingOccurrences(of: "Qwen3-ASR ", with: ""))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(model.quantization.uppercased())
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedModel == model.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("Show advanced Qwen3-ASR variants", isOn: $showAdvancedModels)

                if showAdvancedModels {
                    Picker("Advanced model", selection: $selectedModel) {
                        ForEach(ASRModelCatalog.supportedModels) { model in
                            Text("\(model.title) • \(model.quantization)")
                                .tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text("Current: \(selectedModelLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("ForcedAligner models are excluded here because they are not direct speech-to-text generation models.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct TranscriptionLanguageSection: View {
    @Binding var selectedLanguageID: String

    private var selectedLanguageTitle: String {
        ASRLanguageCatalog.options
            .first(where: { $0.id == ASRLanguageCatalog.normalizedLanguageID(selectedLanguageID) })?
            .title ?? "Auto-detect (recommended)"
    }

    var body: some View {
        Section("Transcription Language") {
            Picker("Language", selection: $selectedLanguageID) {
                ForEach(ASRLanguageCatalog.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            Text("Default is Auto-detect. If you mostly dictate in one language, forcing it can improve accuracy by skipping language identification.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Current: \(selectedLanguageTitle)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

private struct MicrophoneSection: View {
    @ObservedObject var appState: AppState
    let selectedMicrophoneTag: Binding<String>
    let systemDefaultMicrophoneTag: String

    var body: some View {
        Section("Microphone") {
            Picker("Default input", selection: selectedMicrophoneTag) {
                Text("System default").tag(systemDefaultMicrophoneTag)
                ForEach(appState.availableInputDevices) { mic in
                    Text(mic.name).tag(mic.id)
                }
            }
            .pickerStyle(.menu)

            Button("Refresh microphone list") {
                appState.refreshInputDevices()
            }

            if let selectedUID = appState.selectedInputDeviceUID,
               let selectedMic = appState.availableInputDevices.first(where: { $0.id == selectedUID }) {
                Text("Selected microphone: \(selectedMic.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Using system default microphone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("VoiceScribe only opens the microphone while a recording is in progress.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
