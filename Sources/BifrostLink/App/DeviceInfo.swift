import Foundation

enum DeviceInfo {
    private static let lock = NSLock()
    private static var current = "Thor"
    private static var keyword = "thor"

    static var name: String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static var ratingKeyword: String {
        lock.lock()
        defer { lock.unlock() }
        return keyword
    }

    static var isThor: Bool { ratingKeyword == "thor" }

    static func update(model: String) {
        var short = model.trimmingCharacters(in: .whitespaces)
        for prefix in ["AYN ", "Ayn ", "ayn "] where short.hasPrefix(prefix) { short = String(short.dropFirst(prefix.count)) }
        if short.isEmpty { short = "device" }
        short = short.replacingOccurrences(of: #"^Odin(\d)"#, with: "Odin $1", options: .regularExpression)
        let lowered = short.lowercased()
        let family: String
        if lowered.hasPrefix("thor") {
            family = "thor"
        } else if let match = lowered.range(of: #"^odin ?\d*( ?(mini|portal|pro|max))?"#, options: .regularExpression) {
            family = String(lowered[match]).replacingOccurrences(of: " ", with: "")
        } else {
            family = lowered.replacingOccurrences(of: " ", with: "")
        }
        lock.lock()
        current = short
        keyword = family
        lock.unlock()
    }

    static func matches(report device: String) -> Bool {
        let normalized = device.lowercased().replacingOccurrences(of: "ayn", with: "").replacingOccurrences(of: " ", with: "")
        let key = ratingKeyword
        if key == "thor" { return normalized.contains("thor") }
        return normalized.hasPrefix(key) || normalized == key
    }
}
