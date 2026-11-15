import Foundation

/// A saved IP configuration for one network service, applied in one step.
struct IPProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var serviceName: String
    var configuration: IPConfiguration
}

/// Saved IP profiles, kept in user defaults. Saving needs no password;
/// applying one does.
@MainActor
final class IPProfileStore: ObservableObject {
    @Published private(set) var profiles: [IPProfile] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func profiles(for serviceName: String) -> [IPProfile] {
        profiles.filter { $0.serviceName == serviceName }
    }

    func profile(named name: String) -> IPProfile? {
        profiles.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Saves `configuration` under `name` for the service, replacing a
    /// profile with the same name there.
    @discardableResult
    func save(name: String, serviceName: String, configuration: IPConfiguration) -> IPProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = profiles.firstIndex(where: { $0.serviceName == serviceName && $0.name == trimmed }) {
            profiles[index].configuration = configuration
            persist()
            return profiles[index]
        }
        let profile = IPProfile(name: trimmed, serviceName: serviceName, configuration: configuration)
        profiles.append(profile)
        persist()
        return profile
    }

    func delete(_ profile: IPProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func rename(_ profile: IPProfile, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// The profile the service uses right now, if any.
    func activeProfile(for service: IPServiceConfiguration) -> IPProfile? {
        profiles(for: service.serviceName).first { $0.configuration.matches(service.configuration) }
    }

    private func load() {
        guard let data = defaults.data(forKey: PreferenceKeys.ipProfiles),
              let decoded = try? JSONDecoder().decode([IPProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: PreferenceKeys.ipProfiles)
    }
}
