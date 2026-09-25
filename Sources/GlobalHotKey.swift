import Carbon
import Foundation

/// Registers with WindowServer, so emergency restore needs no Accessibility grant.
final class GlobalHotKey {
    private static let hotKeyID = EventHotKeyID(signature: 0x4F534352, id: 1) // OSCR
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    enum RegistrationError: LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                return "Could not install emergency restore keyboard handler (\(status))."
            case .hotKey(let status):
                return "Could not register Control–Option–Command–R (\(status)). Another app may already use this shortcut."
            }
        }
    }

    init(action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard status == noErr,
                      identifier.signature == GlobalHotKey.hotKeyID.signature,
                      identifier.id == GlobalHotKey.hotKeyID.id else {
                    return OSStatus(eventNotHandledErr)
                }
                let shortcut = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                shortcut.action()
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else { throw RegistrationError.eventHandler(handlerStatus) }

        let keyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), Self.hotKeyID,
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard keyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw RegistrationError.hotKey(keyStatus)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
