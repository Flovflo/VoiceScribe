# App Store Preparation

This project now has a concrete App Store distribution path, but a few submission tasks still remain before upload.

## Implemented in this branch

1. Dedicated Xcode app target and archive workflow
- Added `project.yml` plus `scripts/generate_xcodeproj.sh` to generate `VoiceScribe.xcodeproj` with a macOS app target.
- Added `scripts/archive_app_store.sh` to build an archive-ready App Store variant.

2. App Sandbox entitlements
- Added `AppStore/VoiceScribeAppStore.entitlements` with:
- App Sandbox
- microphone access
- outbound network access for model downloads

3. Privacy manifest
- Added `Sources/VoiceScribe/Resources/PrivacyInfo.xcprivacy` with required-reason API declarations for:
- file timestamps
- system boot time
- user defaults

4. App Store metadata drafts
- Added:
- `docs/PRIVACY_POLICY.md`
- `docs/SUPPORT.md`
- `docs/APP_REVIEW_NOTES.md`
- `docs/APP_STORE_METADATA.md`
- `AppStore/Screenshots/README.md`

5. App Store-safe clipboard behavior
- The App Store variant disables `CGEvent` paste injection.
- It still copies the transcript to the clipboard, and the user pastes manually.
- Onboarding and Settings now explain this behavior in the App Store build.

## Remaining work before submission

1. Produce final signed archive
- Build and archive with a valid Apple Developer Team, distribution certificate, and provisioning profile.

2. Capture real App Store screenshots
- Needed:
- HUD idle
- HUD recording
- Settings with model and language selection
- menu bar interaction
- Use `AppStore/Screenshots/README.md` as the capture checklist

3. Fill App Store Connect fields from the drafts
- privacy policy URL
- support URL
- promotional text
- description
- review notes

4. Run final submission checks
- archive validation in Xcode Organizer
- notarization/export sanity check if distributed outside the store as well
- final review of microphone permission copy and sandbox behavior
