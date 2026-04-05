import AppKit
import SwiftUI
import VoiceScribeCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case model
    case shortcut

    var id: Int { rawValue }
}

struct VoiceScribeOnboardingItem: Identifiable {
    let step: OnboardingStep
    let title: String
    let subtitle: String
    let screenshotName: String
    let zoomScale: CGFloat
    let zoomAnchor: UnitPoint

    var id: Int { step.rawValue }
}

struct OnboardingView: View {
    @ObservedObject private var appState = AppState.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("selectedModel") private var selectedModel = ASRModelCatalog.defaultModelID
    @AppStorage(ASRLanguageCatalog.defaultsKey) private var selectedLanguageID = ASRLanguageCatalog.defaultLanguageID

    let finishOnboarding: @MainActor () -> Void

    @State private var activeIndex = 0
    @State private var prepareTask: Task<Void, Never>?

    private var items: [VoiceScribeOnboardingItem] {
        [
            .init(
                step: .welcome,
                title: "Speak anywhere on your Mac",
                subtitle: AppDistribution.supportsAutomaticPaste
                    ? "VoiceScribe floats above your apps, listens in place,\nand pastes the transcript back for you."
                    : "VoiceScribe floats above your apps, listens in place,\nand copies the transcript to your clipboard.",
                screenshotName: "SS2",
                zoomScale: 1.18,
                zoomAnchor: .init(x: 0.52, y: 0.38)
            ),
            .init(
                step: .model,
                title: "Choose your local model",
                subtitle: "Everything stays on-device. Pick your model and keep language on Auto,\nor force one when you want the best recognition accuracy.",
                screenshotName: "template-scene-model",
                zoomScale: 1.82,
                zoomAnchor: .init(x: 1, y: 0.84)
            ),
            .init(
                step: .shortcut,
                title: "Ready from a single shortcut",
                subtitle: "Option + Space opens VoiceScribe instantly.\nWe finish the local setup once, then you're good to go.",
                screenshotName: "SS1",
                zoomScale: 1.24,
                zoomAnchor: .init(x: 0.5, y: 0.34)
            )
        ]
    }

    private var currentStep: OnboardingStep {
        items[activeIndex].step
    }

    var body: some View {
        VoiceScribeTemplateOnboarding(
            items: items,
            activeIndex: $activeIndex,
            selectedModel: $selectedModel,
            selectedLanguageID: $selectedLanguageID,
            appState: appState,
            onExit: completeOnboarding,
            onSkip: completeOnboarding,
            onComplete: completeOnboarding
        )
        .preferredColorScheme(.dark)
        .onAppear(perform: handleAppear)
        .onChange(of: activeIndex) { _, newValue in
            guard items[newValue].step == .shortcut else { return }
            startModelPreparation()
        }
        .onDisappear(perform: cancelTasks)
    }

    private func handleAppear() {
        if !ASRModelCatalog.isSupportedASRModel(selectedModel) {
            selectedModel = ASRModelCatalog.defaultModelID
        }

        let normalizedLanguageID = ASRLanguageCatalog.normalizedLanguageID(selectedLanguageID)
        if normalizedLanguageID != selectedLanguageID {
            selectedLanguageID = normalizedLanguageID
        }
    }

    private func startModelPreparation() {
        if appState.isReady {
            return
        }

        prepareTask?.cancel()
        prepareTask = Task {
            await appState.initialize(modelID: selectedModel)
            await MainActor.run {
                prepareTask = nil
            }
        }
    }

    @MainActor
    private func completeOnboarding() {
        cancelTasks()
        hasCompletedOnboarding = true
        dismissPresentedOnboardingWindow()
        finishOnboarding()
    }

    private func cancelTasks() {
        prepareTask?.cancel()
        prepareTask = nil
    }

    @MainActor
    private func dismissPresentedOnboardingWindow() {
        for window in NSApp.windows
        where window.identifier == AppDelegate.onboardingWindowIdentifier
            || window.title == "Welcome to VoiceScribe" {
            window.orderOut(nil)
            window.close()
        }
    }
}
