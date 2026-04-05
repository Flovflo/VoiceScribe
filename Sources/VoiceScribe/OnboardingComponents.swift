import SwiftUI
import VoiceScribeCore

struct VoiceScribeTemplateOnboarding: View {
    let items: [VoiceScribeOnboardingItem]
    @Binding var activeIndex: Int
    @Binding var selectedModel: String
    @Binding var selectedLanguageID: String
    @ObservedObject var appState: AppState
    let onExit: () -> Void
    let onSkip: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.clear)
                .overlay {
                    ZStack {
                        bezelShape
                            .fill(.windowBackground)

                        ScreenshotView(item: items[activeIndex])
                            .contentTransition(.interpolate)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .compositingGroup()
                            .animation(.easeInOut(duration: 0.5), value: activeIndex)
                            .keyframeAnimator(initialValue: CGFloat.zero, trigger: activeIndex) { content, blur in
                                content.blur(radius: blur)
                            } keyframes: { _ in
                                CubicKeyframe(16, duration: 0.25)
                                CubicKeyframe(0, duration: 0.25)
                            }
                            .clipShape(bezelShape)

                        BezelDesign()
                    }
                }
                .containerShape(.rect(cornerRadius: 5))
                .aspectRatio(screenRatio, contentMode: .fit)
                .frame(height: 290)
                .padding(.top, 10)
                .compositingGroup()
                .scaleEffect(items[activeIndex].zoomScale, anchor: items[activeIndex].zoomAnchor)

            VStack(spacing: 0) {
                VStack(spacing: 20) {
                    IndicatorView()
                        .offset(y: 10)

                    TextContentView()
                }
                .padding(.top, 30)

                ContinueButton()
                    .padding(.top, 20)
            }
            .background(VariableBackground())
        }
        .padding(.vertical, 30)
        .overlay(alignment: .top) {
            HStack {
                Button(action: handleBackOrExit) {
                    Image(systemName: activeIndex == 0 ? "xmark" : "chevron.left")
                        .font(.caption)
                        .contentTransition(.symbolEffect)
                        .foregroundStyle(.secondary)
                        .frame(width: 25, height: 25)
                        .background(.ultraThinMaterial, in: .circle)
                }

                Spacer(minLength: 0)

                Button(action: onSkip) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 25, height: 25)
                        .background(.ultraThinMaterial, in: .circle)
                }
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 600)
        .clipShape(.rect(cornerRadius: 30).inset(by: 0.6))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(.windowBackground)

                RoundedRectangle(cornerRadius: 30)
                    .stroke(.gray.opacity(0.2), lineWidth: 1.2)
            }
        }
    }

    private func handleBackOrExit() {
        if activeIndex == 0 {
            onExit()
        } else {
            withAnimation(.smooth(duration: 0.5, extraBounce: 0)) {
                activeIndex = max(activeIndex - 1, 0)
            }
        }
    }

    @ViewBuilder
    private func BezelDesign() -> some View {
        ZStack(alignment: .top) {
            bezelShape
                .stroke(macbookTint, lineWidth: 4)

            bezelShape
                .stroke(.black, lineWidth: 3)

            bezelShape
                .stroke(.black, lineWidth: 3)
                .padding(2)

            bottomOnlyCornerRadiusShape(3)
                .fill(.black)
                .frame(width: 50, height: 8)
                .offset(y: 3.5)

            bottomOnlyCornerRadiusShape(5)
                .fill(macbookTint)
                .overlay(alignment: .top) {
                    bottomOnlyCornerRadiusShape(3)
                        .fill(.black.opacity(0.3))
                        .frame(width: 45, height: 4)
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, -35)
                .offset(y: 9)
        }
        .padding(-3)
    }

    @ViewBuilder
    private func ScreenshotView(item: VoiceScribeOnboardingItem) -> some View {
        if let image = VoiceScribeOnboardingAsset.image(named: item.screenshotName) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    @ViewBuilder
    private func IndicatorView() -> some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                let isActive = activeIndex == index

                Capsule()
                    .fill(activeTint.opacity(isActive ? 1 : 0.4))
                    .frame(width: isActive ? 25 : 6, height: 6)
            }
        }
        .padding(.bottom, 5)
    }

    @ViewBuilder
    private func TextContentView() -> some View {
        ZStack {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isActive = activeIndex == index

                VStack(spacing: 6) {
                    Text(item.title)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(activeTint)

                    Text(item.subtitle)
                        .font(.title3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(activeTint.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    StepAccessoryView(
                        step: item.step,
                        selectedModel: $selectedModel,
                        selectedLanguageID: $selectedLanguageID,
                        appState: appState
                    )
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .compositingGroup()
                .opacity(isActive ? 1 : 0)
            }
        }
        .compositingGroup()
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: activeIndex) { content, blur in
            content.blur(radius: blur)
        } keyframes: { _ in
            CubicKeyframe(15, duration: 0.25)
            CubicKeyframe(0, duration: 0.25)
        }
    }

    @ViewBuilder
    private func ContinueButton() -> some View {
        Button(action: handleContinue) {
            Text(continueButtonTitle)
                .fontWeight(.medium)
                .contentTransition(.numericText())
                .foregroundStyle(buttonForeground)
                .frame(width: 300, height: 42)
                .background(buttonTint.gradient, in: .capsule)
                .contentShape(.capsule)
                .opacity(canContinue ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
    }

    @ViewBuilder
    private func VariableBackground() -> some View {
        Rectangle()
            .fill(.windowBackground)
            .mask {
                LinearGradient(
                    colors: [
                        .black,
                        .black,
                        .black,
                        .black.opacity(0.9),
                        .black.opacity(0.4),
                        .clear
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
            .padding(.top, -30)
            .padding(.bottom, -50)
    }

    private func handleContinue() {
        guard canContinue else { return }

        if activeIndex == items.count - 1 {
            onComplete()
        } else {
            withAnimation(.smooth(duration: 0.5, extraBounce: 0)) {
                activeIndex = min(activeIndex + 1, items.count - 1)
            }
        }
    }

    private var continueButtonTitle: String {
        switch items[activeIndex].step {
        case .shortcut:
            if appState.isReady {
                return "Get Started"
            }
            return appState.isModelDownloading ? "Downloading..." : "Preparing..."
        default:
            return "Continue"
        }
    }

    private var canContinue: Bool {
        items[activeIndex].step != .shortcut || appState.isReady
    }

    private var screenRatio: CGFloat {
        1.547
    }

    private var macbookTint: Color {
        Color(red: 0.75, green: 0.75, blue: 0.78)
    }

    private func bottomOnlyCornerRadiusShape(_ radius: CGFloat) -> AnyShape {
        .init(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
    }

    private var bezelShape: AnyShape {
        if #available(macOS 26.0, *) {
            return .init(
                ConcentricRectangle(
                    topLeadingCorner: .concentric,
                    topTrailingCorner: .concentric,
                    bottomLeadingCorner: .fixed(0),
                    bottomTrailingCorner: .fixed(0)
                )
            )
        }

        return .init(
            UnevenRoundedRectangle(
                topLeadingRadius: 38,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 38,
                style: .continuous
            )
        )
    }

    private var activeTint: Color {
        .primary
    }

    private var buttonTint: Color {
        .blue
    }

    private var buttonForeground: Color {
        .white
    }
}

private struct StepAccessoryView: View {
    let step: OnboardingStep
    @Binding var selectedModel: String
    @Binding var selectedLanguageID: String
    @ObservedObject var appState: AppState

    private let models = ASRModelCatalog.quickChoices

    var body: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .model:
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(models, id: \.id) { model in
                        Button {
                            selectedModel = model.id
                        } label: {
                            VStack(spacing: 2) {
                                Text(model.title.replacingOccurrences(of: "Qwen3-ASR ", with: ""))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(model.quantization.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedModel == model.id
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                OnboardingLanguageSelection(selectedLanguageID: $selectedLanguageID)
            }
        case .shortcut:
            if appState.isReady {
                HStack(spacing: 10) {
                    KeyCap(text: "⌥")
                    KeyCap(text: "Space")
                    Text("Open, dictate, paste back")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .frame(width: 280)

                    Text(progressLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progressValue: Double {
        min(max(appState.isReady ? 1 : appState.downloadProgress, 0), 1)
    }

    private var progressLabel: String {
        if let errorMessage = appState.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return appState.status
    }
}

private struct OnboardingLanguageSelection: View {
    @Binding var selectedLanguageID: String

    private var selectedLanguageTitle: String {
        ASRLanguageCatalog.options
            .first(where: { $0.id == ASRLanguageCatalog.normalizedLanguageID(selectedLanguageID) })?
            .title ?? "Auto-detect (recommended)"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Language")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("Language", selection: $selectedLanguageID) {
                    ForEach(ASRLanguageCatalog.options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }

            Text("Current: \(selectedLanguageTitle)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private enum VoiceScribeOnboardingAsset {
    static func image(named name: String) -> NSImage? {
        for fileExtension in ["png", "jpg", "jpeg"] {
            if let url = Bundle.module.url(forResource: name, withExtension: fileExtension) {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }
}
