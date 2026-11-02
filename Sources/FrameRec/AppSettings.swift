import AppKit
import Carbon
import FrameRecCore

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }
    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [49: "空格", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }
}

enum ShortcutAction: UInt32, CaseIterable {
    case select = 1, pause = 2, stop = 3
    var title: String {
        switch self { case .select: return "开始框选"; case .pause: return "暂停 / 继续"; case .stop: return "结束并保存" }
    }
    var defaultShortcut: Shortcut {
        let key: (UInt32, String)
        switch self { case .select: key = (UInt32(kVK_ANSI_R), "R")
        case .pause: key = (UInt32(kVK_ANSI_P), "P")
        case .stop: key = (UInt32(kVK_ANSI_S), "S") }
        return Shortcut(keyCode: key.0, modifiers: UInt32(controlKey | optionKey), key: key.1)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var format: MovieFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var frameRate: Int { didSet { defaults.set(frameRate, forKey: "frameRate") } }
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "showsCursor") } }
    @Published var showsToolbar: Bool { didSet { defaults.set(showsToolbar, forKey: "showsToolbar") } }
    @Published private(set) var directory: URL
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        format = MovieFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .mp4
        let fps = defaults.integer(forKey: "frameRate")
        frameRate = [24, 30, 60].contains(fps) ? fps : 30
        showsCursor = defaults.object(forKey: "showsCursor") as? Bool ?? true
        showsToolbar = defaults.object(forKey: "showsToolbar") as? Bool ?? true
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        directory = URL(fileURLWithPath: defaults.string(forKey: "directory") ?? movies.appendingPathComponent("FrameRec").path)
        for action in ShortcutAction.allCases {
            shortcuts[action] = defaults.data(forKey: "shortcut.\(action.rawValue)")
                .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? action.defaultShortcut
        }
    }

    func setDirectory(_ url: URL) {
        directory = url.standardizedFileURL
        defaults.set(directory.path, forKey: "directory")
    }

    func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut.\(action.rawValue)")
    }
}
