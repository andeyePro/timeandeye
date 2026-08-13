// Headless UI snapshots — see timeandeyeUI/SnapshotHarness.swift.
// Usage: swift run timeandeyeSnapshots [outdir]   (default ./snapshots)
#if os(macOS)
import Foundation
import timeandeyeUI

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "snapshots"
let dir = URL(fileURLWithPath: outPath)
let lines = await MainActor.run { SnapshotHarness.renderAll(to: dir) }
for line in lines { print(line) }
if lines.contains(where: { $0.contains("FAILED") }) { exit(1) }
#else
print("timeandeyeSnapshots is macOS-only")
#endif
