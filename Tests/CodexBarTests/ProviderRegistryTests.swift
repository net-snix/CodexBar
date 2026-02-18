import CodexBarCore
import Testing

@Suite
struct ProviderRegistryTests {
    @Test
    func descriptorRegistryIsCompleteAndDeterministic() {
        let descriptors = ProviderDescriptorRegistry.all
        let ids = descriptors.map(\.id)

        #expect(!descriptors.isEmpty, "ProviderDescriptorRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderDescriptorRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing descriptors for providers: \(missing).")

        let secondPass = ProviderDescriptorRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderDescriptorRegistry order changed between reads.")
    }

    @Test
    func codexOnlyRegistryOrder() {
        let ids = ProviderDescriptorRegistry.all.map(\.id)
        #expect(ids == [.codex], "Codex-only mode should expose only Codex in registry order.")
    }
}
