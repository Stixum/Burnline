import Foundation

public struct SettingsStore: Sendable {
    private let url: URL

    public init(directory: URL = ApplicationSupport.directory()) {
        url = directory.appendingPathComponent("settings.json")
    }

    /// Any failure — missing, unreadable, corrupt — falls back to defaults.
    /// Losing settings is annoying; refusing to launch is worse.
    public func load() -> BurnlineSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(BurnlineSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: BurnlineSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
