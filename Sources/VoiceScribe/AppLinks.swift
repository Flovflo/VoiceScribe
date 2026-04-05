import Foundation

enum AppLinks {
    private static let repositoryBaseURL = "https://github.com/Flovflo/VoiceScribe/blob/main/docs"

    static let privacyPolicy = URL(string: "\(repositoryBaseURL)/PRIVACY_POLICY.md")!
    static let support = URL(string: "\(repositoryBaseURL)/SUPPORT.md")!
    static let reviewNotes = URL(string: "\(repositoryBaseURL)/APP_REVIEW_NOTES.md")!
}
