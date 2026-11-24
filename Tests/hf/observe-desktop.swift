// Noninteractive macOS observer for a functional render test (not for timing).
// Usage: swiftc -O observe-desktop.swift -o <scratch>/observe
//        observe <new-proof.json> /absolute/path/to/command [args ...]
import AppKit
import CoreGraphics
import Foundation

func children(of root: pid_t) throws -> [pid_t: String] {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,ppid=,comm="]
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "ps", code: Int(p.terminationStatus)) }
    var graph: [pid_t: [(pid_t, String)]] = [:], rootName = "(command)"
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
        let name = (String(fields[2]) as NSString).lastPathComponent
        graph[parent, default: []].append((pid, name))
        if pid == root { rootName = name }
    }
    var tree = [root: rootName], queue = [root]
    while let parent = queue.popLast() {
        for (pid, exe) in graph[parent] ?? [] where tree[pid] == nil {
            tree[pid] = exe
            queue.append(pid)
        }
    }
    return tree
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args[1].hasPrefix("/"), !FileManager.default.fileExists(atPath: args[0]) else {
    fputs("usage: observe <new-proof.json> /absolute/command [args ...]\n", stderr)
    exit(2)
}
let child = Process()
child.executableURL = URL(fileURLWithPath: args[1])
child.arguments = Array(args.dropFirst(2))
let first = NSWorkspace.shared.frontmostApplication?.processIdentifier
try child.run()
var samples = 0, known = 0, validWindowLists = 0, changed = 0, frontOwned = 0, maxWindows = 0
var seen = Set<String>(), others = Set<String>()
repeat {
    let tree = try children(of: child.processIdentifier)
    for name in tree.values {
        let lower = name.lowercased()
        if lower.contains("chrome") || lower.contains("chromium") || lower == "safari" { others.insert(name) }
        if lower.hasPrefix("safarium-") { seen.insert(name) }
    }
    if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        known += 1
        if front != first { changed += 1 }
        if tree[front] != nil { frontOwned += 1 }
    }
    // Read owner IDs from the visible-window list only. No titles or screen pixels are retained.
    if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]], !info.isEmpty {
        validWindowLists += 1
        let n = info.reduce(0) { count, row in
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  tree[pid] != nil else { return count }
            return count + 1
        }
        maxWindows = max(maxWindows, n)
    }
    samples += 1
    if child.isRunning { Thread.sleep(forTimeInterval: 0.12) }
} while child.isRunning
child.waitUntilExit()
let proof: [String: Any] = ["test_exit": child.terminationStatus, "samples": samples,
    "readable_front_pids": known, "readable_window_lists": validWindowLists,
    "front_different_from_start": changed, "test_tree_front_samples": frontOwned,
    "max_test_tree_onscreen_windows": maxWindows, "renderer_processes_sampled": seen.sorted(),
    "safari_or_chromium_descendants_sampled": others.sorted()]
let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: args[0]), options: .withoutOverwriting)
print(String(decoding: data, as: UTF8.self))
if child.terminationStatus != 0 { exit(child.terminationStatus) }
let usable = known == samples && validWindowLists == samples && !seen.isEmpty
exit(usable && others.isEmpty && maxWindows == 0 && frontOwned == 0 ? 0 : 1)
