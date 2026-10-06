# VoiceScribe 1.5.0

Release for Apple Silicon, macOS 14 or later. Native Liquid Glass requires macOS 26; older systems use system materials. This is the standard clipboard/automatic-paste distribution, built with Swift/MLX. Qwen3-ASR 1.7B 4-bit is the default for new installations; saved choices are preserved.

## Validation and publisher identity

- 88 core tests and 3 HUD tests: zero failures, 8 optional skips. Explicit native FR/EN inference and microphone capture checks are documented in the [macOS audit](AUDIT_MACOS_ASR_2026-10-04.md).
- Developer ID Application: FLORIAN DAMIEN TAFFIN, team `WZ4CHJH7TA`; secure timestamp, hardened runtime and microphone entitlement. No JIT, unsigned executable memory or disabled library validation entitlement.
- App notarization accepted: `35908ec5-f5b4-412c-9d3e-73bf814d24b9`.
- DMG notarization accepted: `1520457f-c976-49d7-b4aa-bcce9685897a`.
- App and DMG tickets stapled and validated; Gatekeeper reports `Notarized Developer ID` for both. ZIP contains the stapled app.
- The GitHub assets contain the app and checksum files only. Model weights download on first use. No signing private key, certificate export, API credential or local user preference is shipped.
- The final binary includes the explicit permission-result member lookup required by Swift 6.3. Core/HUD tests and the arm64 release build were rerun before signing and notarization.

Final SHA-256 checksums, generated after stapling:

| Asset | SHA-256 |
| --- | --- |
| `VoiceScribe-1.5.0-arm64.dmg` | `f1da3014513f6663c689eff8c67176b4a33c9e09c68835739cdd683948009d0e` |
| `VoiceScribe-1.5.0-arm64.zip` | `d2e70a8e8a94de1391110e0662f42a42f8d38c9ed6180bf2cfcc4e610b403486` |

## Security review and remediation

Independent static product review found no outbound audio/transcript upload or Python/subprocess runtime. It identified one conditional medium-severity workflow command-injection issue: a manually supplied tag was substituted into shell source before validation, with a repository-write workflow token. The release workflow now binds values through environment variables, rejects shell syntax/newlines/path traversal, disables checkout credential persistence, uses immutable action SHAs and has read-only repository permissions.

CI now produces explicitly unsigned preview artifacts and cannot publish public releases. The old release workflow is disabled on GitHub until the fixed workflow reaches the default branch; this also prevents it from replacing verified local release assets. CI was moved from Xcode 16.2/Swift 6.0 to a macOS 26/Xcode 26.6 runner compatible with MLX's Swift 6.3 tools requirement.

CI tests compile MLX shaders with Xcode in an isolated standalone copy of the package sources, tests and locked manifest. This avoids selecting the repository's App Store project or excluding dependency tests. The test helper selects the library built with the dependency and excludes system-private and stale working-directory copies. A hosted GPU parity failure exposed the incompatible system-library fallback; the signed app already packages its matching build output.

Rotary-embedding parity retains a `0.0005` bound at short offsets and permits two Float32 epsilon units per scaled cached position at long offsets. The independent `pow`/trig reference and MLX's `exp2(log2(base))`/fast-trig kernel have different phase rounding. The hosted runner measured `0.00068324804` at offset 4096 and length 31, within the resulting `0.0009837151` budget; all other cases already passed the tighter bound. No inference code was changed for this test portability adjustment.

Secret scanning and push protection are enabled. Dependabot alerts and automated security updates were enabled during this release. Initial API readbacks returned no open secret/dependency alerts; that does not establish an exhaustive fresh dependency scan.

GitHub release immutability is enabled: publication locks this release's tag and assets and generates a release attestation. `main` is protected against force pushes and deletion, including administrator pushes. These controls do not claim that every account, dependency or branch change has been independently reviewed.

Review limitations: binary artwork/audio, raw benchmark-result JSON, Git history and exhaustive third-party parser/dependency review were not completed. Production model revisions are still mutable; optional ambient Hugging Face endpoint/token and shared-cache behavior are inherited from the dependency. Clipboard contents remain visible to software with the user's desktop authority. No claim of complete security certification is made.

## Rebuilding a signed app

With an installed Developer ID Application identity and Xcode Metal Toolchain:

```sh
VOICESCRIBE_VERSION=1.5.0 VOICESCRIBE_BUILD=1 \
VOICESCRIBE_REQUIRE_DEVELOPER_ID=1 \
VOICESCRIBE_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
./package_app.sh
```

Then notarize the ZIP with `asc notarization submit`, staple the accepted app, create/sign/notarize/staple the DMG, and verify with `codesign`, `stapler` and `spctl` before publication. Generate SHA-256 checksums **after** stapling. Keep credentials in the keychain or outside the repository.
