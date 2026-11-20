import Foundation
import WinUI
import BezzleCore

/// Home previews run in a copy of Bezzle without a window. The renderer's mutable picture and
/// text state stays in that process, and loading an image cannot block input in the editor.
@MainActor final class HomePreviews {
    private struct Card: Hashable {
        let url: URL
        let version: Date?
        let width: Double
        let scale: Double
    }

    private var pictures: [Card: WriteableBitmap] = [:]
    private var waiting: [Card: [Image]] = [:]
    private var queue: [Card] = []
    private var work: (card: Card, process: Process, directory: URL)?
    private var visible = false
    private var cancelled = false

    func clearCards() {
        waiting.removeAll()
        queue.removeAll()
    }

    func show(_ image: Image, for url: URL, version: Date?, width: Double, scale: Double) {
        let card = Card(url: url, version: version, width: width, scale: scale)
        if let picture = pictures[card] {
            image.source = picture
        } else {
            if waiting[card] == nil, work?.card != card { queue.append(card) }
            waiting[card, default: []].append(image)
        }
    }

    func resume() {
        visible = true
        startNext()
    }

    func pause() {
        visible = false
        guard let work, work.process.isRunning else { return }
        cancelled = true
        work.process.terminate()
    }

    func quit() {
        pause()
        if let work { try? FileManager.default.removeItem(at: work.directory) }
    }

    func startNext() {
        guard visible, work == nil else { return }
        while !queue.isEmpty {
            let card = queue.removeFirst()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle-preview-\(UUID())", isDirectory: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = [HomePreviewWorker.command, card.url.path, directory.path, String(card.width), String(card.scale)]
            process.terminationHandler = { [weak self] ended in
                let succeeded = ended.terminationStatus == 0
                Task { @MainActor [weak self] in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    self?.finished(card, directory: directory, succeeded: succeeded)
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try process.run()
                work = (card, process, directory)
                Trace.time("home preview started \(card.url.lastPathComponent)")
                return
            } catch {
                waiting[card] = nil
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func finished(_ card: Card, directory: URL, succeeded: Bool) {
        work = nil
        if cancelled {
            cancelled = false
            if waiting[card] != nil { queue.insert(card, at: 0) }
        } else if let images = waiting.removeValue(forKey: card), succeeded,
                  let version = card.version, version == Self.version(of: card.url) {
            let width = Int(card.width * card.scale), height = Int(card.width * 300 / 480 * card.scale)
            if let bytes = try? Data(contentsOf: directory.appendingPathComponent("card.bgra")), bytes.count == width * height * 4 {
                let bitmap = WriteableBitmap(Int32(width), Int32(height))
                if let buffer = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) {
                    bytes.withUnsafeBytes { raw in
                        UnsafeMutableRawPointer(buffer).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                    }
                    try? bitmap.invalidate()
                    pictures[card] = bitmap
                    for image in images { image.source = bitmap }
                }
            }
            if Tabs.shared.tab(showing: card.url) == nil {
                let jpeg = try? Data(contentsOf: directory.appendingPathComponent("preview.jpg"))
                WindowsCore.keepHomePreview(jpeg, for: card.url)
            }
            Trace.time("home preview finished \(card.url.lastPathComponent)")
        }
        startNext()
    }

    static func version(of url: URL) -> Date? {
        let document = url.appendingPathComponent("document.json")
        func modified(_ path: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        }
        return modified(document) ?? modified(url)
    }
}

@MainActor enum HomePreviewWorker {
    nonisolated static let command = "--home-preview"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 5, let width = Double(arguments[3]), let scale = Double(arguments[4]),
              width > 0, scale > 0, (2...8192).contains(width * scale) else { return 2 }
        let height = width * 300 / 480
        let w = Int(width * scale), h = Int(height * scale)
        let design = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let fonts = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fonts")
        do {
            WindowsCore.start()
            try WindowsCore.loadFonts(from: fonts)
            var bytes = Data(count: w * h * 4)
            let result = bytes.withUnsafeMutableBytes { pixels in
                WindowsCore.drawHomePreview(of: design, width: width, height: height, scale: scale) { pw, ph in
                    pw == w && ph == h ? pixels.baseAddress : nil
                }
            }
            if result.card { try bytes.write(to: output.appendingPathComponent("card.bgra"), options: .atomic) }
            if let preview = result.package { try preview.write(to: output.appendingPathComponent("preview.jpg"), options: .atomic) }
            return 0
        } catch {
            return 1
        }
    }
}
