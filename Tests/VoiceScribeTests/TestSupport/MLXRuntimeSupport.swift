import Foundation
import MLX
import XCTest

private final class MLXTestBundleMarker: NSObject {}

/// Load the shaders built with this test executable's MLX dependency.
/// System-private and previously copied libraries can have incompatible kernels.
@discardableResult
func ensureMLXRuntimeMetallibAvailable() throws -> URL {
    let candidates = mlxMetalLibrarySourceCandidates()
    for source in candidates {
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        GPU.metallib = source
        return source
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

    let products = Bundle(for: MLXTestBundleMarker.self).bundleURL.deletingLastPathComponent()
    let mlxBundle = products.appendingPathComponent("mlx-swift_Cmlx.bundle", isDirectory: true)
    urls.append(mlxBundle.appendingPathComponent("Contents/Resources/default.metallib"))
    urls.append(mlxBundle.appendingPathComponent("default.metallib"))

    if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
        urls.append(executableDir.appendingPathComponent("mlx.metallib"))
        urls.append(executableDir.appendingPathComponent("Resources/mlx.metallib"))
        urls.append(executableDir.appendingPathComponent("Resources/default.metallib"))
    }

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
