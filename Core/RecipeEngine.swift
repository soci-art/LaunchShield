import Foundation

enum RecipeEngine {
    static func fullPath(_ recipe: Recipe, container: String) -> String {
        container + "/" + recipe.relativePath
    }

    /// 0 bytes = normal; frozen = frozen; a same-name folder = placeholder;
    /// missing = the path has nothing; anything bigger = it came back.
    static func status(_ recipe: Recipe, container: String, channel: Channel) -> RecipeStatus {
        let path = fullPath(recipe, container: container)
        guard let item = channel.item(at: path) else {
            if recipe.placeholder {
                return RecipeStatus(state: .placeholder, size: 0, detail: "原文件已删，同名文件夹占位中")
            }
            return RecipeStatus(state: .missing, size: 0, detail: "这个路径现在什么都没有")
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
