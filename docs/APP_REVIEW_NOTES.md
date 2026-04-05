# App Review Notes

## Summary

VoiceScribe is a menu bar and floating-HUD macOS dictation app. The user starts and stops recording manually with the `Option + Space` hotkey or the menu bar item.

## Review walkthrough

1. Launch the app.
2. Open the HUD from the menu bar or press `Option + Space`.
3. Start speaking to record.
4. Stop recording with `Option + Space`.
5. The transcript is generated on-device and copied to the clipboard.

## Important behavior

- The app records audio only after explicit user action.
- Speech transcription runs locally on-device with MLX.
- On first use, the app may download the selected speech model from Hugging Face over HTTPS and cache it locally.
- The App Store build copies the transcript to the clipboard. It does not inject a paste command into other apps.

## Permissions

- Microphone access is required to record audio.

## No account required

- The app does not require login.
- There is no paywall or in-app purchase flow in the current build.
