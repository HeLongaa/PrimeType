import Cocoa

enum KeyCodeMapper {
    // X11 / Rime modifier masks
    static let kShiftMask: Int32 = 1 << 0
    static let kLockMask: Int32 = 1 << 1
    static let kControlMask: Int32 = 1 << 2
    static let kAltMask: Int32 = 1 << 3
    static let kSuperMask: Int32 = 1 << 26
    static let kReleaseMask: Int32 = 1 << 30

    // Common X11 KeySyms used by librime
    static let XK_BackSpace: Int32 = 0xff08
    static let XK_Tab: Int32 = 0xff09
    static let XK_Return: Int32 = 0xff0d
    static let XK_Escape: Int32 = 0xff1b
    static let XK_Home: Int32 = 0xff50
    static let XK_Left: Int32 = 0xff51
    static let XK_Up: Int32 = 0xff52
    static let XK_Right: Int32 = 0xff53
    static let XK_Down: Int32 = 0xff54
    static let XK_Page_Up: Int32 = 0xff55
    static let XK_Page_Down: Int32 = 0xff56
    static let XK_End: Int32 = 0xff57
    static let XK_Delete: Int32 = 0xffff
    static let XK_Shift_L: Int32 = 0xffe1
    static let XK_Shift_R: Int32 = 0xffe2
    static let XK_space: Int32 = 0x0020

    static func rimeModifiers(from flags: NSEvent.ModifierFlags) -> Int32 {
        var mask: Int32 = 0
        if flags.contains(.shift) { mask |= kShiftMask }
        if flags.contains(.capsLock) { mask |= kLockMask }
        if flags.contains(.control) { mask |= kControlMask }
        if flags.contains(.option) { mask |= kAltMask }
        if flags.contains(.command) { mask |= kSuperMask }
        return mask
    }

    static func rimeKeyCode(from event: NSEvent) -> Int32? {
        switch event.keyCode {
        case 0x24: return XK_Return       // Return
        case 0x30: return XK_Tab          // Tab
        case 0x31: return XK_space        // Space
        case 0x33: return XK_BackSpace    // Delete (Backspace)
        case 0x35: return XK_Escape       // Escape
        case 0x4c: return XK_Return       // Numpad Enter
        case 0x73: return XK_Home         // Home
        case 0x74: return XK_Page_Up      // Page Up
        case 0x75: return XK_Delete       // Forward Delete
        case 0x77: return XK_End          // End
        case 0x79: return XK_Page_Down    // Page Down
        case 0x7b: return XK_Left         // Left Arrow
        case 0x7c: return XK_Right        // Right Arrow
        case 0x7d: return XK_Down         // Down Arrow
        case 0x7e: return XK_Up           // Up Arrow
        default:
            break
        }

        guard let chars = event.characters, let scalar = chars.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        if value >= 0x20 && value <= 0x7e {
            return Int32(value)
        }
        return nil
    }
}
