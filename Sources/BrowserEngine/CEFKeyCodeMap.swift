import Carbon.HIToolbox

/// Maps macOS keyCode (hardware scan code) to Windows virtual key codes
/// used by CEF's key event model.
enum CEFKeyCodeMap {
    static func windowsKeyCode(from macKeyCode: UInt16) -> Int32 {
        switch Int(macKeyCode) {
        case kVK_ANSI_A: return 0x41  // VK_A
        case kVK_ANSI_S: return 0x53
        case kVK_ANSI_D: return 0x44
        case kVK_ANSI_F: return 0x46
        case kVK_ANSI_H: return 0x48
        case kVK_ANSI_G: return 0x47
        case kVK_ANSI_Z: return 0x5A
        case kVK_ANSI_X: return 0x58
        case kVK_ANSI_C: return 0x43
        case kVK_ANSI_V: return 0x56
        case kVK_ANSI_B: return 0x42
        case kVK_ANSI_Q: return 0x51
        case kVK_ANSI_W: return 0x57
        case kVK_ANSI_E: return 0x45
        case kVK_ANSI_R: return 0x52
        case kVK_ANSI_Y: return 0x59
        case kVK_ANSI_T: return 0x54
        case kVK_ANSI_1: return 0x31
        case kVK_ANSI_2: return 0x32
        case kVK_ANSI_3: return 0x33
        case kVK_ANSI_4: return 0x34
        case kVK_ANSI_6: return 0x36
        case kVK_ANSI_5: return 0x35
        case kVK_ANSI_Equal: return 0xBB     // VK_OEM_PLUS
        case kVK_ANSI_9: return 0x39
        case kVK_ANSI_7: return 0x37
        case kVK_ANSI_Minus: return 0xBD     // VK_OEM_MINUS
        case kVK_ANSI_8: return 0x38
        case kVK_ANSI_0: return 0x30
        case kVK_ANSI_RightBracket: return 0xDD  // VK_OEM_6
        case kVK_ANSI_O: return 0x4F
        case kVK_ANSI_U: return 0x55
        case kVK_ANSI_LeftBracket: return 0xDB   // VK_OEM_4
        case kVK_ANSI_I: return 0x49
        case kVK_ANSI_P: return 0x50
        case kVK_ANSI_L: return 0x4C
        case kVK_ANSI_J: return 0x4A
        case kVK_ANSI_Quote: return 0xDE     // VK_OEM_7
        case kVK_ANSI_K: return 0x4B
        case kVK_ANSI_Semicolon: return 0xBA // VK_OEM_1
        case kVK_ANSI_Backslash: return 0xDC // VK_OEM_5
        case kVK_ANSI_Comma: return 0xBC     // VK_OEM_COMMA
        case kVK_ANSI_Slash: return 0xBF     // VK_OEM_2
        case kVK_ANSI_N: return 0x4E
        case kVK_ANSI_M: return 0x4D
        case kVK_ANSI_Period: return 0xBE    // VK_OEM_PERIOD
        case kVK_ANSI_Grave: return 0xC0     // VK_OEM_3
        case kVK_Return: return 0x0D         // VK_RETURN
        case kVK_Tab: return 0x09            // VK_TAB
        case kVK_Space: return 0x20          // VK_SPACE
        case kVK_Delete: return 0x08         // VK_BACK (backspace)
        case kVK_Escape: return 0x1B         // VK_ESCAPE
        case kVK_Command: return 0x5B        // VK_LWIN
        case kVK_Shift: return 0x10          // VK_SHIFT
        case kVK_CapsLock: return 0x14       // VK_CAPITAL
        case kVK_Option: return 0x12         // VK_MENU (Alt)
        case kVK_Control: return 0x11        // VK_CONTROL
        case kVK_RightShift: return 0x10
        case kVK_RightOption: return 0x12
        case kVK_RightControl: return 0x11
        case kVK_F1: return 0x70
        case kVK_F2: return 0x71
        case kVK_F3: return 0x72
        case kVK_F4: return 0x73
        case kVK_F5: return 0x74
        case kVK_F6: return 0x75
        case kVK_F7: return 0x76
        case kVK_F8: return 0x77
        case kVK_F9: return 0x78
        case kVK_F10: return 0x79
        case kVK_F11: return 0x7A
        case kVK_F12: return 0x7B
        case kVK_ForwardDelete: return 0x2E  // VK_DELETE
        case kVK_Home: return 0x24           // VK_HOME
        case kVK_End: return 0x23            // VK_END
        case kVK_PageUp: return 0x21         // VK_PRIOR
        case kVK_PageDown: return 0x22       // VK_NEXT
        case kVK_LeftArrow: return 0x25      // VK_LEFT
        case kVK_RightArrow: return 0x27     // VK_RIGHT
        case kVK_DownArrow: return 0x28      // VK_DOWN
        case kVK_UpArrow: return 0x26        // VK_UP
        default: return 0
        }
    }
}
