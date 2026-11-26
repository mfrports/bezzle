import Foundation
import WinSDK

/// One Bezzle at a time for each copy of Bezzle.exe, as the Mac runs one: a second start, as by a
/// double click in Explorer or a bezzle: link, hands its command line to the copy that runs and
/// quits; that copy opens what it was given, each design in a tab, and comes to the front
/// (`BezzleApp.openCommandLine`).
///
/// How: a named mutex tells a start whether a copy runs already, and a named pipe carries the
/// command line over to it, with the folder it was started in, so names given relative to it
/// still lead somewhere. A pipe rather than WM_COPYDATA: nothing has to find the running copy's
/// window, which WinUI gives the same class as every other WinUI window and a title that changes
/// with the design in front; the pipe is answered on a thread of its own, however busy the window
/// is; and Windows lets only the same person write to it, from this computer only.
///
/// Both are named after this Bezzle.exe by its full path (a hash of it), and the pipe after the
/// Windows session as well: copies started from different folders, as test copies built side by
/// side are, never hand over to each other, nor do two people signed in at once, while every start
/// of one installed copy finds the one that runs.
enum HandOver {
    private static let executablePath: String = {
        var buffer = [UInt16](repeating: 0, count: 32768)
        let count = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer[0..<count], as: UTF16.self)
    }()
    static let executable = URL(fileURLWithPath: executablePath)

    /// This Bezzle.exe as it is told from others: its path, lower case, as a 64-bit FNV-1a hash.
    static let name: String = {
        let path = executablePath.lowercased()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }()

    private static var session: DWORD {
        var id: DWORD = 0
        _ = ProcessIdToSessionId(GetCurrentProcessId(), &id)
        return id
    }

    private static var pipeName: String { "\\\\.\\pipe\\Bezzle-\(session)-\(name)" }

    /// Held for as long as this copy runs, telling later starts that it does.
    nonisolated(unsafe) private static var mutex: HANDLE?
    private static let gate = NSLock()
    nonisolated(unsafe) private static var accepting = true
    nonisolated(unsafe) private static var pending = 0

    /// An accepted launch can still be on its way to the window. Give it its turn before quitting.
    static func stopAccepting() -> Bool {
        gate.withLock {
            guard pending == 0 else { return false }
            accepting = false
            return true
        }
    }

    /// What one start hands to the other.
    private struct Message: Codable {
        var folder: String
        var arguments: [String]
    }

    // Win32's numbers, as the pipe functions take them.
    private static let genericReadWrite: DWORD = 0x8000_0000 | 0x4000_0000
    private static let accessDuplex: DWORD = 0x0000_0003
    private static let firstInstance: DWORD = 0x0008_0000
    private static let rejectRemote: DWORD = 0x0000_0008
    private static let unlimited: DWORD = 255
    private static let alreadyExists: DWORD = 183
    private static let pipeBusy: DWORD = 231
    private static let pipeConnected: DWORD = 535
    private static let fileNotFound: DWORD = 2
    private static let waitAbandoned: DWORD = 0x0000_0080

    /// Whether another copy of this Bezzle.exe runs and has taken `arguments` (with the folder
    /// this one was started in): then this one has nothing more to do. A copy that is starting
    /// may not listen yet; it is waited for a few seconds, and if it never answers, this one runs
    /// after all.
    static func pass(_ arguments: [String]) -> Bool {
        if arguments.first == SavedPreviewWorker.command {
            exit(MainActor.assumeIsolated { SavedPreviewWorker.run(arguments) })
        }
        mutex = "Local\\Bezzle-\(name)".withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
        guard GetLastError() == alreadyExists else { return false }
        let message = Message(folder: FileManager.default.currentDirectoryPath, arguments: arguments)
        guard let body = try? JSONEncoder().encode(message) else { return false }
        for _ in 0..<50 {
            let pipe = pipeName.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, genericReadWrite, 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let pipe, pipe != INVALID_HANDLE_VALUE {
                defer { CloseHandle(pipe) }
                // The running copy may come to the front: this one was started by the person,
                // so Windows lets it pass that on.
                var server: ULONG = 0
                if GetNamedPipeServerProcessId(pipe, &server) { _ = AllowSetForegroundWindow(DWORD(server)) }
                var length = UInt32(body.count).littleEndian
                let header = withUnsafeBytes(of: &length) { Array($0) }
                guard write(pipe, header + [UInt8](body)), let reply = read(pipe, 1) else { return false }
                if reply == [1] { return true }
                // Take over when the old copy ends, or give the launch to the copy that took over.
                guard let mutex else { return false }
                let turn = WaitForSingleObject(mutex, 100)
                if turn == WAIT_OBJECT_0 || turn == waitAbandoned { return false }
                if turn == WAIT_FAILED { return false }
                continue
            }
            let error = GetLastError()
            if error == pipeBusy {
                _ = pipeName.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, 1000) }
            } else if error == fileNotFound {
                // Not listening yet.
                Sleep(100)
            } else {
                return false
            }
        }
        return false
    }

    /// Listens for later starts on a thread of its own; `received` is called on the main thread
    /// with each one's command line and the folder it was started in.
    static func listen(_ received: @escaping @MainActor (_ arguments: [String], _ folder: URL) -> Void) {
        let name = pipeName
        Thread.detachNewThread {
            var first = true
            while true {
                let pipe = name.withCString(encodedAs: UTF16.self) {
                    CreateNamedPipeW($0, accessDuplex | (first ? firstInstance : 0), rejectRemote, unlimited, 4096, 65536, 0, nil)
                }
                // Another copy owns the name (one that ran before this one could take it): this
                // one takes nothing.
                guard let pipe, pipe != INVALID_HANDLE_VALUE else { return }
                first = false
                var message: Message?
                if ConnectNamedPipe(pipe, nil) || GetLastError() == pipeConnected,
                   let header = read(pipe, 4) {
                    let length = Int(UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
                    if length <= 1 << 20, let body = read(pipe, length) {
                        message = try? JSONDecoder().decode(Message.self, from: Data(body))
                    }
                    // Refuse handovers once shutdown begins so they open in the next copy.
                    let willOpen = gate.withLock {
                        guard accepting, message != nil else { return false }
                        pending += 1
                        return true
                    }
                    if !willOpen { message = nil }
                    _ = write(pipe, [willOpen ? 1 : 0])
                    FlushFileBuffers(pipe)
                }
                DisconnectNamedPipe(pipe)
                CloseHandle(pipe)
                if let message {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            received(message.arguments, URL(fileURLWithPath: message.folder, isDirectory: true))
                            gate.withLock { pending -= 1 }
                        }
                    }
                }
            }
        }
    }

    private static func read(_ pipe: HANDLE, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            var n: DWORD = 0
            let ok = out.withUnsafeMutableBytes { ReadFile(pipe, $0.baseAddress! + got, DWORD(count - got), &n, nil) }
            guard ok, n > 0 else { return nil }
            got += Int(n)
        }
        return out
    }

    private static func write(_ pipe: HANDLE, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            var n: DWORD = 0
            let ok = bytes.withUnsafeBytes { WriteFile(pipe, $0.baseAddress! + sent, DWORD(bytes.count - sent), &n, nil) }
            guard ok, n > 0 else { return false }
            sent += Int(n)
        }
        return true
    }
}
