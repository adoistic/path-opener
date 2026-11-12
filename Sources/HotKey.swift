import Foundation
import Carbon

/// The global shortcuts on offer.
enum HotKey: Int, CaseIterable {
    case optCmdO = 0, optSpace, cmdSpace, ctrlSpace

    var label: String {
        switch self {
        case .optCmdO: return "⌥⌘O"
        case .optSpace: return "⌥Space"
        case .cmdSpace: return "⌘Space"
        case .ctrlSpace: return "⌃Space"
        }
    }
    var keyCode: UInt32 { self == .optCmdO ? UInt32(kVK_ANSI_O) : UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .optCmdO: return UInt32(cmdKey | optionKey)
        case .optSpace: return UInt32(optionKey)
        case .cmdSpace: return UInt32(cmdKey)
        case .ctrlSpace: return UInt32(controlKey)
        }
    }
    static var current: HotKey {
        get { HotKey(rawValue: UserDefaults.standard.integer(forKey: "hotkey")) ?? .optCmdO }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }
}
