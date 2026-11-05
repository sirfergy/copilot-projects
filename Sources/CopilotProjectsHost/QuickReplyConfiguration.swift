import Foundation
import CopilotProjectsProtocol

public extension QuickReplyConfiguration {
    static func load(from defaults: UserDefaults) -> QuickReplyConfiguration {
        resolved(fromJSON: defaults.string(forKey: storageKey))
    }

    @discardableResult
    static func save(
        _ items: [QuickReplyItem],
        to defaults: UserDefaults
    ) -> Result<[QuickReplyItem], QuickReplyValidationError> {
        switch validateList(items) {
        case .failure(let error):
            return .failure(error)
        case .success(let validated):
            guard let data = try? JSONEncoder().encode(validated),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(.emptyLabel)
            }
            defaults.set(json, forKey: storageKey)
            return .success(validated)
        }
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }
}
