import Foundation

enum SnapshotDiff {
    /// Walk the container without following symbolic links. Both file and
    /// directory counts are bounded so malformed or unusually large trees
    /// cannot monopolize the caller's background task.
    static func take(bundleID: String,
                     root: String,
                     channel: Channel,
                     limit: Int = 60000,
                     directoryLimit: Int = 120000) throws -> ContainerSnapshot {
        let safeFileLimit = max(1, limit)
        let safeDirectoryLimit = max(1, directoryLimit)
        var entries: [String: ContainerSnapshot.Entry] = [:]
        var stack: [(path: String, relative: String)] = [(root, "")]
        var visitedDirectories = 0
        var truncated = false
        var reachedLimit = false

        while let current = stack.popLast() {
            visitedDirectories += 1
            if visitedDirectories > safeDirectoryLimit {
                truncated = true
                break
            }

            let children: [FileItem]
            do {
                children = try channel.children(of: current.path)
            } catch {
                // Keep a partial snapshot, but make the loss of coverage
                // explicit so callers do not treat it as a complete baseline.
                truncated = true
                continue
            }

            // Stable traversal order makes repeated snapshots easier to
            // compare and makes limit truncation reproducible.
            for item in children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                if item.isSymlink { continue }
                let relative = current.relative.isEmpty ? item.name : current.relative + "/" + item.name
                if item.isDirectory {
                    stack.append((path: item.path, relative: relative))
                } else {
                    if entries.count >= safeFileLimit {
                        truncated = true
                        reachedLimit = true
                        break
                    }
                    entries[relative] = ContainerSnapshot.Entry(size: item.size,
                                                                modified: item.modified.timeIntervalSince1970)
                }
            }
            if reachedLimit { break }
        }

        return ContainerSnapshot(bundleID: bundleID,
                                 root: root,
                                 createdAt: Date(),
                                 truncated: truncated,
                                 entries: entries)
    }

    /// New files first, then files that grew. Candidates remain suggestions;
    /// the scoring layer and the user's selection decide what is actionable.
    static func diff(before: ContainerSnapshot,
                     after: ContainerSnapshot,
                     appName: String = "") -> [DiffCandidate] {
        var result: [DiffCandidate] = []
        for (path, entry) in after.entries {
            let old = before.entries[path]
            if let old, entry.size <= old.size { continue }

            let delta = old.map { entry.size - $0.size } ?? entry.size
            // DiffCandidate stores a signed delta; saturate rather than
            // allowing an oversized UInt64 conversion to wrap negative.
            let signedDelta = delta > UInt64(Int64.max) ? Int64.max : Int64(delta)
            result.append(DiffCandidate(relativePath: path,
                                        size: entry.size,
                                        modified: Date(timeIntervalSince1970: entry.modified),
                                        reason: old.map { "变大了 \(Format.bytes(delta))" } ?? "刚新增",
                                        isNew: old == nil,
                                        delta: signedDelta,
                                        appName: appName,
                                        bundleID: after.bundleID,
                                        containerRoot: after.root))
        }
        result.sort { first, second in
            if first.isNew != second.isNew { return first.isNew }
            if first.isNew { return first.modified > second.modified }
            if first.delta != second.delta { return first.delta > second.delta }
            return first.relativePath.localizedStandardCompare(second.relativePath) == .orderedAscending
        }
        return Array(result.prefix(400))
    }
}
