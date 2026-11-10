// Video Splitter — cuts big videos into clips that each stay under a size limit (default 400 MB).
// Clips are cut without re-encoding, so quality is unchanged and it is fast.
// Build with ./build.sh (needs only the Xcode Command Line Tools).

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Splitting engine

struct SplitError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

final class CancelFlag: @unchecked Sendable { var cancelled = false }

func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

/// A path in `dir` that does not exist yet: "name.ext", then "name (2).ext", …
func freeURL(in dir: URL, name: String, ext: String) -> URL {
    var url = dir.appendingPathComponent(name).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
        n += 1
    }
    return url
}

enum Splitter {
    /// Splits `src` into clips of at most `limitBytes` inside `outDir`.
    /// `progress` gets (fraction of the whole video done, clip number being written).
    static func split(src: URL, outDir: URL, limitBytes: Int64, cancel: CancelFlag,
                      progress: @escaping (Double, Int) -> Void) async throws -> [URL] {
        let size = fileSize(src)
        guard size > 0 else { throw SplitError("The file is missing or empty.") }
        let base = src.deletingPathExtension().lastPathComponent

        if size <= limitBytes {   // already small enough: just put a copy in the save folder
            let dst = freeURL(in: outDir, name: base, ext: src.pathExtension)
            try FileManager.default.copyItem(at: src, to: dst)
            progress(1, 1)
            return [dst]
        }

        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { throw SplitError("Could not read this video.") }

        // Aim a little under the limit, because bitrate varies through a video.
        let target = Double(limitBytes) * 0.90
        let chunk = total / (Double(size) / target).rounded(.up)

        var types: [AVFileType] = [.mp4, .mov]
        var outputs: [URL] = []
        var start = 0.0
        var part = 1
        do {
            while start < total - 0.05 {
                let remaining = total - start
                var length = remaining / max(1, (remaining / chunk - 0.001).rounded(.up))
                var attempt = 0
                while true {
                    if cancel.cancelled { throw CancellationError() }
                    attempt += 1
                    let from = start, len = length, number = part
                    let url = try await exportPiece(asset: asset, start: from, length: len, outDir: outDir,
                                                    name: "\(base) - part \(String(format: "%02d", number))",
                                                    types: &types, cancel: cancel) { f in
                        progress(min(1, (from + len * f) / total), number)
                    }
                    let got = fileSize(url)
                    if got <= limitBytes { outputs.append(url); break }
                    try? FileManager.default.removeItem(at: url)   // too big: cut a shorter piece
                    if attempt >= 8 || length < 0.5 {
                        throw SplitError("Could not cut a clip small enough for this limit.")
                    }
                    length *= Double(limitBytes) / Double(got) * 0.93
                }
                start += length
                part += 1
            }
        } catch {
            for u in outputs { try? FileManager.default.removeItem(at: u) }   // leave no half-finished set
            throw error
        }
        progress(1, part - 1)
        return outputs
    }

    private static func exportPiece(asset: AVAsset, start: Double, length: Double, outDir: URL, name: String,
                                    types: inout [AVFileType], cancel: CancelFlag,
                                    onProgress: @escaping (Double) -> Void) async throws -> URL {
        var lastError: Error = SplitError("This video format cannot be split.")
        while let type = types.first {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw SplitError("This video format cannot be split.")
            }
            guard session.supportedFileTypes.contains(type) else { types.removeFirst(); continue }
            let url = freeURL(in: outDir, name: name, ext: type == .mp4 ? "mp4" : "mov")
            session.outputURL = url
            session.outputFileType = type
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                            duration: CMTime(seconds: length, preferredTimescale: 60000))
            let poll = Task {
                while !Task.isCancelled {
                    if cancel.cancelled { session.cancelExport() }
                    onProgress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            await session.export()
            poll.cancel()
            removeScratchFiles(beside: url)
            switch session.status {
            case .completed:
                return url
            case .cancelled:
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            default:
                try? FileManager.default.removeItem(at: url)
                lastError = session.error ?? lastError
                types.removeFirst()   // e.g. audio that .mp4 cannot hold: try .mov
            }
        }
        throw lastError
    }

    private static func removeScratchFiles(beside url: URL) {
        let dir = url.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(url.lastPathComponent + ".sb-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// MARK: - App state

struct VideoItem: Identifiable {
    enum Status: Equatable {
        case waiting
        case working(Double, Int)
        case done(Int)
        case failed(String)
    }
    let id = UUID()
    let url: URL
    let size: Int64
    var duration: Double?
    var status: Status = .waiting
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var outDir: URL?
    @Published var limitMB: Double = 400
    @Published var running = false
    @Published var message = ""
    @Published var dropTargeted = false
    static let shared = Model()
    private var cancel = CancelFlag()

    var limitBytes: Int64 { Int64(max(limitMB, 1) * 1_000_000) }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var hasWork: Bool { items.contains { if case .done = $0.status { return false } else { return true } } }

    func clipEstimate(_ item: VideoItem) -> Int {
        item.size <= limitBytes ? 1 : Int((Double(item.size) / (Double(limitBytes) * 0.9)).rounded(.up))
    }
    var totalClips: Int {
        items.reduce(0) { sum, item in
            if case .done(let n) = item.status { return sum + n }
            return sum + clipEstimate(item)
        }
    }

    func add(_ urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.url == url }) else { continue }
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .movie) || type.conforms(to: .video) else { continue }
            let item = VideoItem(url: url, size: fileSize(url))
            items.append(item)
            let id = item.id
            Task {
                let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
                if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].duration = seconds }
            }
        }
        message = ""
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "Choose videos to split"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Where should the clips be saved?"
        panel.message = "Choose the folder to save the clips in"
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outDir ?? items.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        outDir = url
        return true
    }

    func remove(_ item: VideoItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll(); message = "" }

    func stop() {
        cancel.cancelled = true
        message = "Stopping…"
    }

    func start() {
        guard !running, hasWork else { return }
        guard limitMB >= 5 else { message = "The clip size must be at least 5 MB."; return }
        if outDir == nil, !chooseFolder() { return }
        guard let outDir else { return }
        running = true
        message = ""
        cancel = CancelFlag()
        let flag = cancel
        let limit = limitBytes
        let queue = items.filter { if case .done = $0.status { return false } else { return true } }
        Task {
            var made = 0, failed = 0
            for item in queue {
                if flag.cancelled { break }
                let id = item.id
                self.set(id, .working(0, 1))
                do {
                    let clips = try await Splitter.split(src: item.url, outDir: outDir, limitBytes: limit,
                                                         cancel: flag) { fraction, part in
                        Task { @MainActor in
                            if self.running, !flag.cancelled { self.set(id, .working(fraction, part)) }
                        }
                    }
                    made += clips.count
                    self.set(id, .done(clips.count))
                } catch is CancellationError {
                    self.set(id, .waiting)
                } catch {
                    failed += 1
                    self.set(id, .failed(error.localizedDescription))
                }
            }
            self.running = false
            if flag.cancelled {
                self.message = "Stopped."
            } else if failed > 0 {
                self.message = "\(made) clip\(made == 1 ? "" : "s") saved, \(failed) video\(failed == 1 ? "" : "s") failed."
            } else {
                self.message = "Done — \(made) clip\(made == 1 ? "" : "s") saved."
                NSWorkspace.shared.open(outDir)
            }
        }
    }

    private func set(_ id: UUID, _ status: VideoItem.Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }
}

// MARK: - Interface

func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func durationText(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) min" }
    if s >= 60 { return "\(s / 60) min \(s % 60) s" }
    return "\(s) s"
}

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VideoRow: View {
    @EnvironmentObject var model: Model
    let item: VideoItem

    var detail: String {
        var parts = [sizeText(item.size)]
        if let d = item.duration, d.isFinite { parts.append(durationText(d)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if case .working(let fraction, _) = item.status {
                    ProgressView(value: fraction).controlSize(.small)
                }
                if case .failed(let why) = item.status {
                    Text(why).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            switch item.status {
            case .waiting:
                let n = model.clipEstimate(item)
                Text(n == 1 ? "already small — will copy" : "about \(n) clips")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.running {
                    Button { model.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove from list")
                }
            case .working(let fraction, let part):
                Text("clip \(part) · \(Int(fraction * 100))%")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            case .done(let n):
                Label("\(n) clip\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scissors")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Splitter").font(.title2.weight(.bold))
                    Text("Cuts big videos into clips under your size limit, with no quality loss.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.chooseVideos() } label: { Label("Add Videos…", systemImage: "plus") }
                    .disabled(model.running)
            }
            .padding(16)

            HStack(spacing: 10) {
                StatTile(label: "Videos", value: "\(model.items.count)")
                StatTile(label: "Total size", value: model.items.isEmpty ? "—" : sizeText(model.totalSize))
                StatTile(label: "Clips", value: model.items.isEmpty ? "—" : "\(model.totalClips)")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                if model.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop videos here").font(.title3.weight(.medium))
                        Text("or click Add Videos…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                            .foregroundStyle(model.dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.chooseVideos() }
                    .padding(.horizontal, 16)
                } else {
                    List(model.items) { item in VideoRow(item: item) }
                        .listStyle(.inset)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 12)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Max size per clip").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("400", value: $model.limitMB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("MB")
                    }
                }
                GridRow {
                    Text("Save clips to").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(model.outDir?.path(percentEncoded: false) ?? "Not chosen yet — you will be asked")
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(model.outDir == nil ? .secondary : .primary)
                        Spacer()
                        Button(model.outDir == nil ? "Choose…" : "Change…") { model.chooseFolder() }
                    }
                }
            }
            .disabled(model.running)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Text(model.message).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let dir = model.outDir, !model.running, model.items.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                    Button("Show Clips in Finder") { NSWorkspace.shared.open(dir) }
                }
                Button("Clear List") { model.clear() }
                    .disabled(model.running || model.items.isEmpty)
                if model.running {
                    Button("Stop") { model.stop() }.controlSize(.large)
                } else {
                    Button("Split Videos") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.hasWork)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 660, minHeight: 520)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.running else { return false }
            model.add(urls)
            return true
        } isTargeted: { model.dropTargeted = $0 }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SplitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Video Splitter", id: "main") {
            ContentView().environmentObject(Model.shared)
        }
        .defaultSize(width: 720, height: 600)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Headless mode for testing:  VideoSplitter --cli <video> <output folder> <limit MB>
        if args.count == 5, args[1] == "--cli", let mb = Double(args[4]) {
            setvbuf(stdout, nil, _IONBF, 0)
            Task.detached {
                do {
                    var last = -1
                    let clips = try await Splitter.split(src: URL(fileURLWithPath: args[2]),
                                                         outDir: URL(fileURLWithPath: args[3]),
                                                         limitBytes: Int64(mb * 1_000_000),
                                                         cancel: CancelFlag()) { fraction, part in
                        let pct = Int(fraction * 10) * 10
                        if pct != last { last = pct; print("clip \(part): \(pct)%") }
                    }
                    for c in clips { print("\(c.lastPathComponent)  \(sizeText(fileSize(c)))") }
                    exit(0)
                } catch {
                    print("failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        SplitterApp.main()
    }
}
