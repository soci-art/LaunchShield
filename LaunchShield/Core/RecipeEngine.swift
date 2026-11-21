import Foundation

enum RecipeEngine {
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func fullPath(_ recipe: Recipe, container: String) -> String {
        container + "/" + recipe.relativePath
    }

    /// 0 bytes = normal; frozen = frozen; a same-name folder = placeholder;
    /// missing = the path has nothing; anything bigger = it came back.
    static func status(_ recipe: Recipe, container: String, channel: Channel) -> RecipeStatus {
        guard isSafeRelativePath(recipe.relativePath) else {
            return RecipeStatus(state: .unknown, size: 0, detail: "守护记录中的相对路径不安全，已拒绝访问")
        }
        let path = fullPath(recipe, container: container)
        let item: FileItem
        do {
            guard let inspected = try channel.inspectItem(at: path) else {
                if recipe.placeholder {
                    return RecipeStatus(state: .placeholder, size: 0, detail: "原文件已删，同名文件夹占位中")
                }
                return RecipeStatus(state: .missing, size: 0, detail: "这个路径现在什么都没有")
            }
            item = inspected
        } catch {
            return RecipeStatus(state: .unknown, size: 0, detail: "无法读取目标状态：\(error.localizedDescription)")
        }
        if item.isSymlink {
            return RecipeStatus(state: .unknown, size: 0, detail: "目标变成符号链接，已拒绝跟随")
        }
        if item.isDirectory {
            return RecipeStatus(state: .placeholder, size: 0, detail: "同名文件夹占位中")
        }
        if item.size == 0 {
            let frozen = channel.isImmutable(path)
            return RecipeStatus(state: frozen ? .frozen : .normal,
                                size: 0,
                                detail: frozen ? "0 字节，已冻结" : "0 字节")
        }
        return RecipeStatus(state: .recurred,
                            size: item.size,
                            detail: "又变成 \(Format.bytes(item.size)) 了")
    }
}
