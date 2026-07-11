import Foundation
import Security

guard CommandLine.arguments.count == 5 else {
    fputs(
        "usage: swift scripts/import-apns-key.swift <AuthKey.p8> <key-id> <team-id> <bundle-id>\n",
        stderr
    )
    exit(2)
}

let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyData = try Data(contentsOf: keyURL)
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.obvioussean.copilot-projects.apns",
    kSecAttrAccount as String: "provider-key",
]
let status: OSStatus
if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
    status = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: keyData] as CFDictionary
    )
} else {
    var item = query
    item[kSecValueData as String] = keyData
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    status = SecItemAdd(item as CFDictionary, nil)
}
guard status == errSecSuccess else {
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}

let defaults = UserDefaults(suiteName: "com.obvioussean.copilot-projects")!
defaults.set(CommandLine.arguments[2], forKey: "remoteAccess.apnsKeyID")
defaults.set(CommandLine.arguments[3], forKey: "remoteAccess.apnsTeamID")
defaults.set(CommandLine.arguments[4], forKey: "remoteAccess.apnsTopic")
print("APNs provider key and configuration saved. Relaunch Copilot Projects.")
