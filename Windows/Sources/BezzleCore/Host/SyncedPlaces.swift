import Foundation
import WinSDK

/// Folders that the computers of those working in them keep in step, as Windows has them: OneDrive,
/// Google Drive, Dropbox, Box, iCloud Drive, or a server's (the Mac's SyncedFolders). A design kept
/// in one is shared through it (see `FolderShare`), with everyone the folder is shared with.
nonisolated enum SyncedPlaces {
    #if DEBUG
    /// Folders treated as synced in tests, with the service each stands for.
    nonisolated(unsafe) static var forTests: [String: String] = [:]
    #endif

    /// The path Windows gives a file: `C:\Users\…`, as typed.
    static func path(of url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    /// The service that keeps the folder holding `design` in step with other computers, by name;
    /// nil when it is on this computer alone.
    static func service(of design: URL) -> String? {
        let folder = path(of: design.standardizedFileURL.deletingLastPathComponent())
        let here = folder.lowercased().replacingOccurrences(of: "/", with: "\\")
        func inside(_ prefix: String) -> Bool {
            var p = prefix.lowercased().replacingOccurrences(of: "/", with: "\\")
            while p.hasSuffix("\\") { p.removeLast() }
            return !p.isEmpty && (here == p || here.hasPrefix(p + "\\"))
        }
        #if DEBUG
        for (prefix, name) in forTests where inside(prefix) { return name }
        if let synced = ProcessInfo.processInfo.environment["BEZZLE_SYNCED_FOLDER"], !synced.isEmpty, inside(synced) { return "Google Drive" }
        #endif
        for (name, root) in roots() where inside(root) { return name }
        if here.hasPrefix("\\\\") {
            // A server's share, \\server\share\…
            return folder.split(separator: "\\").first.map(String.init)
        }
        guard let volume = volume(of: folder) else { return nil }
        // Google Drive for desktop keeps its files on a drive of its own, by that name.
        if volume.label.lowercased() == "google drive" { return "Google Drive" }
        if volume.remote { return volume.label.isEmpty ? (folder as NSString).lastPathComponent : volume.label }
        return nil
    }

    /// Where the services put their folders on this computer, by service.
    static func roots() -> [(name: String, path: String)] {
        let env = ProcessInfo.processInfo.environment
        var out: [(String, String)] = []
        for key in ["OneDrive", "OneDriveConsumer", "OneDriveCommercial"] {
            if let path = env[key], !path.isEmpty { out.append(("OneDrive", path)) }
        }
        // Dropbox says where its folders are in info.json.
        for base in [env["APPDATA"], env["LOCALAPPDATA"]].compactMap({ $0 }) {
            let file = URL(fileURLWithPath: base).appendingPathComponent("Dropbox").appendingPathComponent("info.json")
            guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (_, account) in json {
                if let path = (account as? [String: Any])?["path"] as? String { out.append(("Dropbox", path)) }
            }
        }
        if let home = env["USERPROFILE"] {
            out.append(("Box", home + "\\Box"))
            out.append(("iCloud Drive", home + "\\iCloudDrive"))
            // Google Drive for desktop, keeping a copy of My Drive on this computer.
            out.append(("Google Drive", home + "\\My Drive"))
        }
        return out
    }

    /// The name of the drive a path is on, and whether it is on another computer.
    private static func volume(of path: String) -> (label: String, remote: Bool)? {
        var root = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let found = path.withCString(encodedAs: UTF16.self) { GetVolumePathNameW($0, &root, DWORD(root.count)) }
        guard found else { return nil }
        let remote = GetDriveTypeW(root) == UINT(DRIVE_REMOTE)
        var label = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let named = GetVolumeInformationW(root, &label, DWORD(label.count), nil, nil, nil, nil, 0)
        return (named ? String(decodingCString: label, as: UTF16.self) : "", remote)
    }
}
