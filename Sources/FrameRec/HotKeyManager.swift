import AppKit
import Carbon
import FrameRecCore

@MainActor
final class HotKeyManager {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onAction: ((UInt32) -> Void)?
    private let signature: OSType = 0x46524543 // FREC

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            let actionID = identifier.id
            DispatchQueue.main.async { manager.onAction?(actionID) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut, id: UInt32) throws {
        unregister(id)
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            throw FrameRecError.message("快捷键 \(shortcut.label) 无法注册，可能已被其他应用使用。")
        }
        references[id] = reference
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }

    func setEscapeEnabled(_ enabled: Bool) {
        if enabled, references[99] == nil {
            try? register(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, key: "Esc"), id: 99)
        } else if !enabled { unregister(99) }
    }

    func invalidate() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
