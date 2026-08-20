import Foundation
import Testing
@testable import OpenYoinkModuleCore

@Suite("Island module configuration")
struct ModuleCoreTests {
    @Test("Configuration removes duplicates and caps pinned modules")
    func normalization() {
        let ids = (0..<8).map { IslandModuleID(rawValue: "module.\($0)") }
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: ids + [ids[0]],
            pinnedModuleIDs: ids + [ids[1]]
        )

        #expect(configuration.enabledModuleIDs.count == 8)
        #expect(configuration.pinnedModuleIDs == Array(ids.prefix(5)))
    }

    @Test("Disabling a module also unpins it")
    func disablingUnpins() {
        let id: IslandModuleID = "timer"
        var configuration = IslandModuleConfiguration(
            enabledModuleIDs: [id], pinnedModuleIDs: [id]
        )

        configuration.setEnabled(false, for: id)

        #expect(!configuration.isEnabled(id))
        #expect(!configuration.isPinned(id))
    }

    @Test("Unknown identifiers survive Codable round trip")
    func unknownRoundTrip() throws {
        let unknown: IslandModuleID = "future.provider.module"
        let original = IslandModuleConfiguration(
            enabledModuleIDs: [unknown], pinnedModuleIDs: [unknown]
        )

        let decoded = try JSONDecoder().decode(
            IslandModuleConfiguration.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }

    @Test("Pinning enables a module")
    func pinningEnables() {
        let id: IslandModuleID = "system"
        var configuration = IslandModuleConfiguration(
            enabledModuleIDs: [], pinnedModuleIDs: []
        )

        configuration.setPinned(true, for: id)

        #expect(configuration.isEnabled(id))
        #expect(configuration.isPinned(id))
    }
}
