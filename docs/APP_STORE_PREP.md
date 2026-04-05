# App Store Preparation

This project is close to a polished macOS app, but it is not yet ready for a Mac App Store submission.

## Current blockers

1. No Xcode app target or archive workflow
The app is currently packaged with `package_app.sh` from a Swift Package build. Mac App Store submissions need an Xcode-managed app target and archive/export flow.

2. No App Sandbox entitlements
The installed app is ad-hoc signed and currently has no entitlements. A Mac App Store build needs at minimum:
- App Sandbox
- microphone access entitlement
- network client entitlement for model downloads

3. No privacy manifest
There is currently no `PrivacyInfo.xcprivacy` included in the app bundle. This is required for uploads when the app or bundled dependencies access required-reason APIs.

4. Metadata is not yet submission-ready
Before submission, App Store Connect still needs:
- privacy policy URL
- support URL
- screenshots that show the real app in use
- review notes explaining microphone capture, local model download, and text pasting behavior

5. Cross-app text injection needs review-note coverage
VoiceScribe simulates `Cmd+V` into the active app. This behavior should be explained clearly in App Review notes and may need a sandbox-compatible implementation strategy for the App Store build.

## Improvements already completed

- Added transcription language selection in Settings and onboarding.
- Fixed packaging to include SwiftPM resource bundles inside `VoiceScribe.app`, which is required for assets and dependency bundles at runtime.

## Recommended next steps

1. Create a dedicated macOS app target in Xcode.
2. Add and validate App Sandbox entitlements.
3. Add a `PrivacyInfo.xcprivacy` file with the required accessed API reasons.
4. Decide how App Store builds should handle cross-app paste behavior.
5. Prepare App Store Connect metadata, screenshots, and review notes.
