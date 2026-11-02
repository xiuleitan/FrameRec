import Foundation

public final class HistoryStore {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public let directory: URL
    public private(set) var recordings: [Recording] = []
    private let fileManager: FileManager
    private var indexURL: URL { directory.appendingPathComponent(".framerec-history.json") }
    public var stagingDirectory: URL { directory.appendingPathComponent(".framerec-staging", isDirectory: true) }

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: indexURL.path) {
            recordings = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: indexURL))
            // Validate before performing any cleanup; never follow paths out of the selected library.
            for recording in recordings { _ = try fileURL(for: recording) }
        }
        recordings.sort { $0.createdAt > $1.createdAt }
    }

    public func fileURL(for recording: Recording) throws -> URL {
        guard !recording.fileName.isEmpty, recording.fileName == (recording.fileName as NSString).lastPathComponent,
              !recording.fileName.hasPrefix("."),
              ["mp4", "mov"].contains((recording.fileName as NSString).pathExtension.lowercased()) else {
            throw FrameRecError.message("历史记录包含无效的文件路径，已停止清理。")
        }
        return directory.appendingPathComponent(recording.fileName)
    }

    public func add(_ recording: Recording, moving source: URL) throws {
        let destination = try fileURL(for: recording)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FrameRecError.message("保存位置已有同名文件。")
        }
        try fileManager.moveItem(at: source, to: destination)
        let previous = recordings
        recordings.insert(recording, at: 0)
        do { try persist() } catch {
            recordings = previous
            try? fileManager.moveItem(at: destination, to: source)
            throw error
        }
    }

    public func update(_ recording: Recording) throws {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            throw FrameRecError.message("这条历史记录已不存在。")
        }
        let previous = recordings[index]
        recordings[index] = recording
        do { try persist() } catch { recordings[index] = previous; throw error }
    }

    public func replace(_ recording: Recording, with source: URL) throws {
        let destination = try fileURL(for: recording)
        let backupName = "\(UUID().uuidString).backup"
        _ = try fileManager.replaceItemAt(destination, withItemAt: source, backupItemName: backupName,
                                         options: [.withoutDeletingBackupItem])
        let backup = directory.appendingPathComponent(backupName)
        do {
            try update(recording)
            try? fileManager.removeItem(at: backup)
        } catch {
            _ = try? fileManager.replaceItemAt(destination, withItemAt: backup)
            throw error
        }
    }

    public func delete(_ recording: Recording) throws {
        let url = try fileURL(for: recording)
        // Stage removal so an index write failure can be rolled back without losing the video.
        let staged = stagingDirectory.appendingPathComponent("\(UUID().uuidString).deleted")
        let exists = fileManager.fileExists(atPath: url.path)
        if exists { try fileManager.moveItem(at: url, to: staged) }
        let previous = recordings
        recordings.removeAll { $0.id == recording.id }
        do { try persist() } catch {
            recordings = previous
            if exists { try? fileManager.moveItem(at: staged, to: url) }
            throw error
        }
        if exists { try fileManager.removeItem(at: staged) }
    }

    @discardableResult
    public func cleanExpired(now: Date = Date(), excluding protected: Set<UUID> = []) throws -> Int {
        let expired = recordings.filter {
            now.timeIntervalSince($0.createdAt) > Self.retention && !protected.contains($0.id)
        }
        for recording in expired { try delete(recording) }
        return expired.count
    }

    public func removeMissingEntries() throws {
        let previous = recordings
        recordings = try recordings.filter { fileManager.fileExists(atPath: try fileURL(for: $0).path) }
        if previous != recordings {
            do { try persist() } catch { recordings = previous; throw error }
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recordings).write(to: indexURL, options: .atomic)
    }
}
