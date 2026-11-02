import Foundation
import Testing
@testable import FrameRecCore

final class HistoryTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRecTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func add(_ name: String, at date: Date, store: HistoryStore) throws -> Recording {
        let temporary = store.stagingDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: temporary)
        let recording = Recording(fileName: name, createdAt: date, duration: 5, width: 100, height: 100,
                                  frameRate: 30, format: .mp4, title: name)
        try store.add(recording, moving: temporary)
        return recording
    }

    @Test func testCleanupOnlyDeletesExpiredRegisteredFiles() throws {
        let store = try HistoryStore(directory: directory)
        let now = Date()
        let expired = try add("expired.mp4", at: now.addingTimeInterval(-HistoryStore.retention - 1), store: store)
        let boundary = try add("boundary.mp4", at: now.addingTimeInterval(-HistoryStore.retention), store: store)
        let exported = directory.appendingPathComponent("exported-copy.mp4")
        try Data("export".utf8).write(to: exported)
        #expect(try store.cleanExpired(now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: try store.fileURL(for: expired).path))
        #expect(FileManager.default.fileExists(atPath: try store.fileURL(for: boundary).path))
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(try HistoryStore(directory: directory).recordings == [boundary])
    }

    @Test func testOpenEditorProtectsExpiredFileAndEditsDoNotResetRetention() throws {
        let store = try HistoryStore(directory: directory)
        let now = Date()
        var recording = try add("open.mp4", at: now.addingTimeInterval(-HistoryStore.retention - 1), store: store)
        recording.modifiedAt = now
        try store.update(recording)
        #expect(try store.cleanExpired(now: now, excluding: [recording.id]) == 0)
        #expect(try store.cleanExpired(now: now) == 1)
    }

    @Test func testReplacementUpdatesFileButPreservesRecordingDate() throws {
        let store = try HistoryStore(directory: directory)
        var recording = try add("edit.mp4", at: Date(timeIntervalSince1970: 100), store: store)
        let staged = store.stagingDirectory.appendingPathComponent("edited.mp4")
        try Data("edited".utf8).write(to: staged)
        recording.duration = 3
        try store.replace(recording, with: staged)
        #expect(try Data(contentsOf: store.fileURL(for: recording)) == Data("edited".utf8))
        #expect(try HistoryStore(directory: directory).recordings.first?.createdAt == recording.createdAt)
    }

    @Test func testPathTraversalInManifestPreventsCleanup() throws {
        let escaped = Recording(fileName: "../outside.mp4", duration: 1, width: 100, height: 100, frameRate: 30, format: .mp4, title: "invalid")
        try JSONEncoder().encode([escaped]).write(to: directory.appendingPathComponent(".framerec-history.json"))
        #expect(throws: FrameRecError.self) { try HistoryStore(directory: directory) }
    }
}
