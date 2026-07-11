import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class CloudflareSession: NSObject {
    static let origin = URL(string: "https://projects.thefergies.com")!
    private static let keychainService =
        "com.sirfergy.copilotprojects.cloudflare-access"
    private static let keychainAccount = "cookies"

    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
    }

    private(set) var cookieHeader: String?
    private(set) var expiresAt: Date?
    var needsLogin = false

    var isAuthenticated: Bool {
        cookieHeader != nil && (expiresAt == nil || expiresAt! > Date())
    }

    override init() {
        super.init()
        load()
        if !isAuthenticated { needsLogin = true }
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

    func refreshFromWebKit() async {
        let cookies = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        let allowed = cookies.filter {
            let domain = $0.domain.trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            return ["projects.thefergies.com", "thefergies.com"].contains(domain)
                && ($0.name == "CF_Authorization" || $0.name == "CF_AppSession")
        }
        guard allowed.contains(where: { $0.name == "CF_Authorization" }) else {
            return
        }
        let stored = allowed.map {
            StoredCookie(
                name: $0.name,
                value: $0.value,
                domain: $0.domain,
                path: $0.path,
                expires: $0.expiresDate
            )
        }
        persist(stored)
        apply(stored)
        needsLogin = false
    }

    func markExpired() {
        needsLogin = true
        cookieHeader = nil
        expiresAt = nil
        KeychainStore.remove(
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }

    func logout() async {
        markExpired()
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where cookie.name.hasPrefix("CF_") {
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    private func load() {
        guard let data = KeychainStore.data(
            service: Self.keychainService,
            account: Self.keychainAccount
        ), let cookies = try? JSONDecoder().decode(
            [StoredCookie].self,
            from: data
        ) else { return }
        apply(cookies)
    }

    private func persist(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        try? KeychainStore.set(
            data,
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }

    private func apply(_ cookies: [StoredCookie]) {
        let valid = cookies.filter {
            $0.expires == nil || $0.expires! > Date()
        }
        guard valid.contains(where: { $0.name == "CF_Authorization" }) else {
            return
        }
        cookieHeader = valid
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        expiresAt = valid.first {
            $0.name == "CF_Authorization"
        }?.expires
    }
}

extension CloudflareSession: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            await self.refreshFromWebKit()
        }
    }
}
