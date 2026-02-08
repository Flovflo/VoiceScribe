import Foundation
import XCTest

/// Ensure MLX runtime metallib exists at the default runtime lookup location.
/// Returns destination URL in current working directory if available.
@discardableResult
func ensureMLXRuntimeMetallibAvailable() throws -> URL {
    let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("default.metallib")

    if FileManager.default.fileExists(atPath: destination.path) {
        return destination
    }

    let candidates = mlxMetalLibrarySourceCandidates()
    for source in candidates {
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            continue
        }
    }

    let preview = candidates.prefix(5).map(\.path).joined(separator: ", ")
    throw XCTSkip("MLX metallib not found. Checked: \(preview)")
}

func mlxMetalLibrarySourceCandidates() -> [URL] {
    var urls = [URL]()

    let env = ProcessInfo.processInfo.environment
    if let explicit = env["VOICESCRIBE_MLX_METALLIB_PATH"], !explicit.isEmpty {
        urls.append(URL(fileURLWithPath: explicit))
    }

    if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
        urls.append(executableDir.appendingPathComponent("mlx.metallib"))
        urls.append(executableDir.appendingPathComponent("Resources/mlx.metallib"))
        urls.append(executableDir.appendingPathComponent("Resources/default.metallib"))
    }

    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    urls.append(cwd.appendingPathComponent("mlx.metallib"))
    urls.append(cwd.appendingPathComponent("default.metallib"))

    // Known macOS-provided MLX metallib locations.
    urls.append(URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CorePhotogrammetry.framework/Versions/A/Resources/mlx.metallib"))
    urls.append(URL(fileURLWithPath: "/System/Library/PrivateFrameworks/GESS.framework/Versions/A/Resources/mlx.metallib"))

    // Mirror SWIFTPM_BUNDLE lookup in mlx-swift C++ runtime when available.
    for bundle in Bundle.allBundles + Bundle.allFrameworks {
        let name = bundle.bundleURL.lastPathComponent
        let identifier = bundle.bundleIdentifier ?? ""
        guard name.contains("mlx-swift_Cmlx") || identifier.contains("mlx-swift_Cmlx") else {
            continue
        }
        guard let resourceURL = bundle.resourceURL else { continue }
        urls.append(resourceURL.appendingPathComponent("default.metallib"))
    }

    var seen = Set<String>()
    return urls.filter { seen.insert($0.path).inserted }
}
