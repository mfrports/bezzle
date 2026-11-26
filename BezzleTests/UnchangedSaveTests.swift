import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// A design saved with nothing changed keeps its file and the date it was last changed.
@MainActor
struct UnchangedSaveTests {
    @Test func sameBytesKeepTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Kept.bezzle")
        var doc = BezzleDocument()
        doc.nodes = [Node(kind: .rectangle, name: "R", frame: CGRect(x: 0, y: 0, width: 40, height: 40))]
        try DesignFile.write(doc, to: url)
        let json = url.appendingPathComponent(DesignFile.documentName)
        let long = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: json.path)
        func modified() throws -> Date? { try FileManager.default.attributesOfItem(atPath: json.path)[.modificationDate] as? Date }

        try DesignFile.write(doc, to: url, keepingSame: true)
        #expect(try modified() == long)

        // Written as before unless asked to keep it.
        try DesignFile.write(doc, to: url)
        #expect(try modified() != long)

        try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: json.path)
        doc.nodes[0].cornerRadius = 6
        try DesignFile.write(doc, to: url, keepingSame: true)
        #expect(try modified() != long)
        #expect(try DesignFile.read(url).nodes.first?.cornerRadius == 6)
    }
}
