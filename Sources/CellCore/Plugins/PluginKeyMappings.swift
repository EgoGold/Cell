import Foundation

enum PluginKeyMappings {
    // macOS virtual key codes are physical keys in the ANSI layout.
    static let codes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "enter": 36, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49, "backspace": 51,
        "escape": 53, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    static func environment(_ mappings: [String: String], program: String) -> [String: String] {
        let entries = mappings.sorted { $0.key < $1.key }.compactMap { key, target -> String? in
            guard let from = codes[key.lowercased()], let to = codes[target.lowercased()], from != to else { return nil }
            return "\(from):\(to)"
        }
        return ["CELL_KEY_MAP": entries.joined(separator: ","), "CELL_KEY_MAP_PROGRAM": program]
    }
}
