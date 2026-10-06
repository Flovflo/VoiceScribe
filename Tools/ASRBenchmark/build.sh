#!/bin/zsh
set -euo pipefail
benchmark_dir="${0:A:h}"
benchmark_build_dir="${ASR_BENCHMARK_BUILD_DIR:-/tmp/voicescribe-benchmark-build}"
swift package --package-path "$benchmark_dir" --scratch-path "$benchmark_build_dir" resolve
parakeet_source="$benchmark_build_dir/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift"
compatibility_patch="$benchmark_dir/Compatibility/parakeet-swift6.patch"
if patch --dry-run --silent -R -p1 -d "$benchmark_build_dir/checkouts/mlx-audio-swift" < "$compatibility_patch" >/dev/null 2>&1; then
    print 'Swift 6 compatibility patch already applied.'
else
    chmod u+w "$parakeet_source"
    patch --forward -p1 -d "$benchmark_build_dir/checkouts/mlx-audio-swift" < "$compatibility_patch"
fi
swift build -c release --package-path "$benchmark_dir" --scratch-path "$benchmark_build_dir"
swift test -c release --package-path "$benchmark_dir" --scratch-path "$benchmark_build_dir"
swift build -c release --package-path "$benchmark_dir" --scratch-path "$benchmark_build_dir" --show-bin-path
