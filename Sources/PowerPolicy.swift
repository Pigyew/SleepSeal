import Foundation

enum PowerPolicy {
    static let binaryKeys: Set<String> = ["powernap", "tcpkeepalive", "womp", "proximitywake"]

    static func valid(_ value: PowerValue) -> Bool {
        guard ["-b", "-c"].contains(value.scope) else { return false }
        if value.key == "powermode" { return (0...2).contains(value.value) }
        if value.key == "lowpowermode" || binaryKeys.contains(value.key) {
            return (0...1).contains(value.value)
        }
        return false
    }

    static func desired(_ value: PowerValue) -> Int {
        ["powermode", "lowpowermode"].contains(value.key) ? 1 : 0
    }

    // Parse each power source independently; preserve High Power Mode (2) too.
    static func parse(_ text: String) -> [PowerValue] {
        var scope: String?
        var values: [PowerValue] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" { scope = "-b"; continue }
            if line == "AC Power:" { scope = "-c"; continue }
            if line.hasSuffix(":") { scope = nil; continue }
            guard let source = scope else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let number = Int(fields[1]) else { continue }
            let value = PowerValue(scope: source, key: String(fields[0]), value: number)
            if valid(value) { values.append(value) }
        }
        let modernSources = Set(values.filter { $0.key == "powermode" }.map(\.scope))
        return values.filter { !($0.key == "lowpowermode" && modernSources.contains($0.scope)) }
    }
}

