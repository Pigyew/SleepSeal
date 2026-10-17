import Foundation

enum AppLanguage: String, Codable, CaseIterable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var onboardingCompleted: Bool
    var triggerPolicy: TriggerPolicy
    var language: AppLanguage
    var launchAtLogin: Bool
    var protectionPaused: Bool
    var quitBlockingApps: Bool

    var protectionEnabled: Bool { onboardingCompleted && !protectionPaused }

    init(existingInstallation: Bool = false, onboardingCompleted: Bool? = nil,
         triggerPolicy: TriggerPolicy = TriggerPolicy(), language: AppLanguage = .system,
         launchAtLogin: Bool = true, protectionPaused: Bool = false, quitBlockingApps: Bool = false) {
        schemaVersion = Self.currentSchemaVersion
        self.onboardingCompleted = onboardingCompleted ?? existingInstallation
        self.triggerPolicy = triggerPolicy
        self.language = language
        self.launchAtLogin = launchAtLogin
        self.protectionPaused = protectionPaused
        self.quitBlockingApps = quitBlockingApps
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, onboardingCompleted, triggerPolicy, language, launchAtLogin, protectionPaused, quitBlockingApps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        onboardingCompleted = try values.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        triggerPolicy = try values.decodeIfPresent(TriggerPolicy.self, forKey: .triggerPolicy) ?? TriggerPolicy()
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        protectionPaused = try values.decodeIfPresent(Bool.self, forKey: .protectionPaused) ?? false
        quitBlockingApps = try values.decodeIfPresent(Bool.self, forKey: .quitBlockingApps) ?? false
    }
}

enum AppConfigurationError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This configuration requires a newer SleepSeal version (schema \(version))."
        }
    }
}

/// User-domain settings only. This store is deliberately separate from the
/// pending recovery record and persistent macOS power-setting backup.
final class AppConfigurationStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SleepSeal", isDirectory: true)
            .appendingPathComponent("configuration.json")
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = AppConfigurationStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Reading a new installation never writes defaults or enables protection.
    /// The migration caller supplies evidence of an existing installation so
    /// an upgrade retains its former all-sleep protection behavior.
    func load(existingInstallation: Bool = false) throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AppConfiguration(existingInstallation: existingInstallation)
        }
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fileURL))
        try validate(configuration)
        return configuration
    }

    func save(_ configuration: AppConfiguration) throws {
        try validate(configuration)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func validate(_ configuration: AppConfiguration) throws {
        guard configuration.schemaVersion == AppConfiguration.currentSchemaVersion else {
            throw AppConfigurationError.unsupportedVersion(configuration.schemaVersion)
        }
    }
}
