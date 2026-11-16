import SwiftUI
import UIKit

struct ContainerBrowserView: View {
    let bundleID: String
    let appName: String

    @State private var root = ""
    @State private var path = ""
    @State private var items: [FileItem] = []
    @State private var errorText: String?
    @State private var preview: FileItem?
    @State private var isLoading = false

    var body: some View {
        SheetPage("\(appName) 的容器") {
            VStack(spacing: 12) {
                breadcrumb
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 20)
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                open(item)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                            if item.id != items.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.06))
                                    .padding(.leading, 56)
                            }
                        }
                        if items.isEmpty && !isLoading && errorText == nil {
                            Text("这个文件夹是空的。")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondaryText)
                                .padding(20)
                        }
                    }
                    .padding(.horizontal, 15)
                    .panel()
                }
            }
            .padding(20)
        }
        .task {
            setup()
        }
        .sheet(item: $preview) { item in
            FilePreviewSheet(item: item)
        }
    }

    private func setup() {
        guard path.isEmpty else { return }
        guard let container = Channel.shared.containerPath(for: bundleID) else {
            errorText = "没有找到这个应用的数据容器。请先在系统里打开一次这个应用。"
            return
        }
        root = container
        path = container
        reload()
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            path = item.path
            reload()
        } else {
            preview = item
        }
    }

    private func reload() {
        guard !path.isEmpty else { return }
        isLoading = true
        let target = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try Channel.shared.children(of: target)
                DispatchQueue.main.async {
                    self.items = list
                    self.errorText = nil
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.items = []
                    self.errorText = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private var relativeComponents: [String] {
        guard !root.isEmpty, path.hasPrefix(root) else { return [] }
        let suffix = String(path.dropFirst(root.count))
        return suffix.split(separator: "/").map(String.init)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    path = root
                    reload()
                } label: {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
                ForEach(Array(relativeComponents.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.secondaryText.opacity(0.6))
                    Button {
                        path = root + "/" + relativeComponents.prefix(index + 1).joined(separator: "/")
                        reload()
                    } label: {
                        Text(component)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 11) {
            if item.isDirectory {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 34, height: 34)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentCyan.opacity(0.8))
                }
            } else {
                ThumbnailView(path: item.path, kind: item.kind, side: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if !item.isDirectory {
                        Text(item.sizeText)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondaryText)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondaryText.opacity(0.6))
                    }
                    Text(item.modifiedText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                    if item.isImmutable {
                        Text("已冻结")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            Spacer()
            Image(systemName: item.isDirectory ? "chevron.right" : "eye")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondaryText.opacity(0.7))
        }
        .padding(.vertical, 9)
    }
}

struct FilePreviewSheet: View {
    let item: FileItem

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        SheetPage(item.name) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if failed || item.kind == .other {
                        VStack(spacing: 8) {
                            Image(systemName: item.kind.symbol)
                                .font(.system(size: 40))
                                .foregroundStyle(Color.secondaryText)
                            Text(item.kind == .video ? "视频只做了缩略图预览" : "这个类型不能预览")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .panel()
                    } else {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        InfoLine(label: "完整路径", value: item.path)
                        InfoLine(label: "大小", value: item.sizeText)
                        InfoLine(label: "修改时间", value: Format.fullDate(item.modified))
                        InfoLine(label: "状态", value: item.isImmutable ? "已冻结" : "普通")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                }
                .padding(20)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        if item.kind == .video {
            let loaded = await ThumbnailLoader.load(path: item.path, kind: .video)
            image = loaded
            failed = loaded == nil
            return
        }
        guard item.kind == .image else { return }
        let path = item.path
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Channel.shared.read(path, maxBytes: 48_000_000)
                continuation.resume(returning: data.flatMap { UIImage(data: $0) })
            }
        }
        image = loaded
        failed = loaded == nil
    }
}
