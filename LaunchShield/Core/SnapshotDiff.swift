import Foundation

enum SnapshotDiff {
    /// Walks the whole container. Directories are followed, links are not;
    /// the walk stops after `limit` files so a huge container cannot stall the
    /// app, and the snapshot records that it was truncated.
    static func take(bundleID: String, root: String, channel: Channel, limit: Int = 60000) throws -> ContainerSnapshot {
        var entries: [String: ContainerSnapshot.Entry] = [:]
        var stack: [(path: String, relative: String)] = [(root, "")]
        var truncated = false
        var reachedLimit = false

        while let current = stack.popLast() {
            let children: [FileItem]
            do {
                children = try channel.children(of: current.path)
            } catch {
                truncated = true
                continue
            }
            for item in children {
                if item.isSymlink { continue }
                let relative = current.relative.isEmpty ? item.name : current.relative + "/" + item.name
                if item.isDirectory {
                    stack.append((path: item.path, relative: relative))
                } else {
                    if entries.count >= limit {
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

    /// New files first, then the ones that clearly grew. Unchanged files are
    /// not candidates; a candidate is only a suggestion until the user picks it.
    static func diff(before: ContainerSnapshot, after: ContainerSnapshot, appName: String = "") -> [DiffCandidate] {
        var result: [DiffCandidate] = []
        for (path, entry) in after.entries {
            if let old = before.entries[path] {
                guard entry.size > old.size else { continue }
                result.append(DiffCandidate(relativePath: path,
                                            size: entry.size,
                                            modified: Date(timeIntervalSince1970: entry.modified),
                                            reason: "变大了 \(Format.bytes(entry.size - old.size))",
                                            isNew: false,
                                            delta: Int64(entry.size - old.size),
                                            appName: appName,
                                            bundleID: after.bundleID,
                                            containerRoot: after.root))
            } else {
                result.append(DiffCandidate(relativePath: path,
                                            size: entry.size,
                                            modified: Date(timeIntervalSince1970: entry.modified),
                                            reason: "刚新增",
                                            isNew: true,
                                            delta: Int64(entry.size),
                                            appName: appName,
                                            bundleID: after.bundleID,
                                            containerRoot: after.root))
            }
        }
        result.sort { first, second in
            if first.isNew != second.isNew { return first.isNew }
            if first.isNew { return first.modified > second.modified }
            return first.delta > second.delta
        }
        return Array(result.prefix(400))
    }
}
