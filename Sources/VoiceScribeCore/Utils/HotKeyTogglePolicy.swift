public enum HotKeyTogglePolicyAction: Equatable, Sendable {
    case toggleRecordingOnly
    case showHUDThenToggleRecording
}

public struct HotKeyTogglePolicy: Sendable {
    public init() {}

    public func action(windowVisible: Bool) -> HotKeyTogglePolicyAction {
        windowVisible ? .toggleRecordingOnly : .showHUDThenToggleRecording
    }
}
