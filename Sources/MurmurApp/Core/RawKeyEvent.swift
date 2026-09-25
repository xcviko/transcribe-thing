import Foundation

/// A physical key transition, forwarded by the hotkey monitor for the onboarding keyboard illustration.
struct RawKeyEvent: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case fn, space, escape, command, option, control, shift
        case other(UInt16)
    }

    var key: Key
    var isDown: Bool

    init(key: Key, isDown: Bool) {
        self.key = key
        self.isDown = isDown
    }
}

extension RawKeyEvent.Key {
    /// Maps a virtual key code (either side for modifiers) to the illustrated key.
    init(keyCode: UInt16) {
        switch keyCode {
        case KeyCode.function: self = .fn
        case KeyCode.space: self = .space
        case KeyCode.escape: self = .escape
        case KeyCode.command, KeyCode.rightCommand: self = .command
        case KeyCode.option, KeyCode.rightOption: self = .option
        case KeyCode.control, KeyCode.rightControl: self = .control
        case KeyCode.shift, KeyCode.rightShift: self = .shift
        default: self = .other(keyCode)
        }
    }
}
