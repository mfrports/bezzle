import Foundation
import BezzleCore

/// Renders previews from saved packages in a separate process, one at a time.
@MainActor final class SavedPreviews {
    static let shared = SavedPreviews()

    private struct Job {
        let revision: WindowsCore.SavedPreview
        var finished: (Bool) -> Void
    }

    private var queue: [Job] = []
    private var active: Job?
    private var process: Process?
    private var scratch: URL?
    private var quitting = false
    private var onQuit: (() -> Void)?

    func enqueue(_ revision: WindowsCore.SavedPreview, finished: @escaping (Bool) -> Void) {
        guard !quitting else { return }
        if active?.revision == revision {
            active?.finished = finished
            return
        }
        queue.removeAll { $0.revision.url == revision.url }
        queue.append(Job(revision: revision, finished: finished))
        startNext()
    }

    func finish(_ done: @escaping () -> Void) {
        quitting = true
        onQuit = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        startNext()
    }

    private func startNext() {
        guard active == nil else { return }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle-saved-preview-\(UUID())", isDirectory: true)
            let output = directory.appendingPathComponent("preview.jpg")
            let child = Process()
            child.executableURL = HandOver.executable
            child.arguments = [SavedPreviewWorker.command, job.revision.url.path, output.path]
            child.terminationHandler = { [weak self] ended in
                let success = ended.terminationStatus == 0
                Task { @MainActor [weak self] in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    self?.complete(ended, output: output, succeeded: success)
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try child.run()
                active = job
                process = child
                scratch = directory
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak child] in
                    MainActor.assumeIsolated {
                        guard let child, child === self?.process, child.isRunning else { return }
                        child.terminate()
                    }
                }
                return
            } catch {
                Trace.say("Could not start the saved preview worker: \(error)")
                try? FileManager.default.removeItem(at: directory)
                job.finished(false)
            }
        }
        let done = onQuit
        onQuit = nil
        done?()
    }

    private func stop() {
        guard onQuit != nil else { return }
        queue.removeAll()
        if let process, process.isRunning { process.terminate() }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        process = nil
        scratch = nil
        active = nil
        startNext()
    }

    private func complete(_ ended: Process, output: URL, succeeded: Bool) {
        guard ended === process, let job = active else { return }
        active = nil
        process = nil
        scratch = nil
        var kept = false
        if succeeded, let jpeg = try? Data(contentsOf: output) {
            kept = WindowsCore.keepSavedPreview(jpeg, for: job.revision)
        } else {
            Trace.say("Could not render a saved package preview")
        }
        job.finished(kept)
        startNext()
    }
}

@MainActor enum SavedPreviewWorker {
    nonisolated static let command = "--saved-preview"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3 else { return 2 }
        let design = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        let fonts = HandOver.executable.deletingLastPathComponent().appendingPathComponent("fonts")
        do {
            WindowsCore.start()
            try WindowsCore.loadFonts(from: fonts)
            try WindowsCore.renderSavedPreview(of: design).write(to: output, options: .atomic)
            return 0
        } catch {
            return 1
        }
    }
}
