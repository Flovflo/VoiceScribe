import Foundation

enum VoiceScribeResourceBundle {
    static let current: Bundle = {
        #if SWIFT_PACKAGE
        .module
        #else
        if let appBundleURL = Bundle.main.resourceURL?.appendingPathComponent("VoiceScribe_VoiceScribe.bundle"),
           let bundle = Bundle(url: appBundleURL) {
            return bundle
        }
        return Bundle.main
        #endif
    }()
}
