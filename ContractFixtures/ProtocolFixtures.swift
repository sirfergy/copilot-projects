import Foundation

/// Shared wire examples for native and JavaScript contract tests, not app data.
public enum ProtocolFixtures {
    public static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
