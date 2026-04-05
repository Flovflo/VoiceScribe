import Foundation

public enum AppDistribution {
    public static let isAppStoreBuild: Bool = {
        #if VOICESCRIBE_APP_STORE
        true
        #else
        false
        #endif
    }()

    public static var supportsAutomaticPaste: Bool {
        !isAppStoreBuild
    }
}
