import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor,
/// which is the modern-looking option and the wrong one here: a global monitor
/// requires Accessibility access. This app already asks for that for one
/// optional feature and states in its security policy that it uses it for
/// nothing else, so spending the same permission on a keyboard shortcut would
/// make that claim untrue. `RegisterEventHotKey` needs no permission at all,
/// and the API being old does not make it deprecated.
///
/// The other reason: a global monitor only observes. Registering claims the
/// combination, so it works when another app has focus, which is the entire
/// point of a hotkey for a utility you reach for when something else is busy.
@MainActor
public final class Hotkey {
    public static let shared = Hotkey()

    /// ⌥⌘B. Not a plain function key or anything an app is likely to want:
    /// registration is first-come, and stealing a combination someone uses in
    /// their editor is a bad trade for a shortcut they press twice a week.
    public struct Combo: Equatable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public static let `default` = Combo(keyCode: UInt32(kVK_ANSI_B),
                                            modifiers: UInt32(optionKey | cmdKey))
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Whether the combination is currently ours. False means something else
    /// already holds it — worth surfacing rather than failing silently, because
    /// from the outside a hotkey that was never registered and one that is
    /// being swallowed look identical.
    public private(set) var isRegistered = false

    private init() {}

    public func register(_ combo: Combo = .default, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // The callback is a C function pointer, so it cannot capture self. It
        // carries a pointer to us instead, and every path out of it is on the
        // main actor because the action touches the UI.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.action?() } }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)

        let id = EventHotKeyID(signature: OSType(0x42535421), id: 1)   // 'BST!'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        isRegistered = (status == noErr)
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        isRegistered = false
    }
}
