import Foundation
import Security

/// Configuration for verifying Cloudflare Access identity tokens. These values
/// come from the self-hosted Access application: the team domain hosts the
/// signing keys, `audTag` is the application's AUD, and `allowedEmail` is the
/// single identity permitted to drive the terminal.
struct CloudflareAccessConfig: Sendable, Equatable {
    let teamDomain: String   // e.g. "thefergies.cloudflareaccess.com"
    let audTag: String       // Access application AUD tag
    let allowedEmail: String // e.g. "obvioussean@github.com"

    var issuer: String { "https://\(teamDomain)" }
    var certsURL: URL { URL(string: "https://\(teamDomain)/cdn-cgi/access/certs")! }
}

/// Verifies the `Cf-Access-Jwt-Assertion` JWT that Cloudflare's edge injects on
/// every request it forwards. Verifying the RS256 signature against Cloudflare's
/// published keys (not merely trusting the email header) is what ties a request
/// to a real Access login for our allowed identity.
///
/// Key fetching is a blocking network call and must run off the event loop via
/// `refreshKeys()`; `verify(token:)` only reads the cached keys so it is cheap
/// on the request hot path.
final class CloudflareAccessVerifier: @unchecked Sendable {
    let config: CloudflareAccessConfig
    private let lock = NSLock()
    private var keysByKid: [String: SecKey] = [:]
    private var reactiveRefreshInFlight = false
    private var lastReactiveRefresh = Date.distantPast
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URL) async -> Data?

    init(
        config: CloudflareAccessConfig,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping @Sendable (URL) async -> Data? = {
            await CloudflareAccessVerifier.fetchData($0)
        }
    ) {
        self.config = config
        self.now = now
        self.fetch = fetch
    }

    /// Fetches Cloudflare's Access signing certificates and caches one public
    /// key per `kid`. Returns true if at least one key was loaded. Blocking —
    /// callers can await this without blocking an event-loop or cooperative thread.
    @discardableResult
    func refreshKeys() async -> Bool {
        guard let data = await fetch(config.certsURL),
              let parsed = Self.parseCerts(data), !parsed.isEmpty else {
            return false
        }
        replaceKeys(parsed)
        return true
    }

    private func replaceKeys(_ keys: [String: SecKey]) {
        lock.lock()
        keysByKid = keys
        lock.unlock()
    }

    /// Seeds a public key for a `kid` directly; used by tests to avoid network
    /// and X.509 generation.
    func installKey(kid: String, key: SecKey) {
        lock.lock()
        keysByKid[kid] = key
        lock.unlock()
    }

    private func key(for kid: String) -> SecKey? {
        var shouldRefresh = false
        lock.lock()
        let key = keysByKid[kid]
        if key == nil,
           !reactiveRefreshInFlight,
           now().timeIntervalSince(lastReactiveRefresh) >= 60 {
            reactiveRefreshInFlight = true
            lastReactiveRefresh = now()
            shouldRefresh = true
        }
        lock.unlock()
        if shouldRefresh {
            Task.detached { [weak self] in
                guard let self else { return }
                _ = await self.refreshKeys()
                self.finishReactiveRefresh()
            }
        }
        return key
    }

    private func finishReactiveRefresh() {
        lock.lock()
        reactiveRefreshInFlight = false
        lock.unlock()
    }

    /// Verifies signature and claims. Returns true only for a well-formed RS256
    /// token signed by a known key, not expired, issued by our team, carrying
    /// our AUD, and whose email matches the single allowed identity.
    func verify(token: String) -> Bool {
        verifiedExpiration(token: token) != nil
    }

    /// Returns the verified token expiration so long-lived responses can enforce
    /// the same authorization deadline that was checked when the request began.
    func verifiedExpiration(token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16_384,
              segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty }),
              let headerData = Self.base64URLDecode(String(segments[0])),
              let payloadData = Self.base64URLDecode(String(segments[1])),
              let signature = Self.base64URLDecode(String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              kid.utf8.count <= 256,
              let publicKey = key(for: kid) else {
            return nil
        }

        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            nil
        ) else {
            return nil
        }

        guard let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return validate(claims: claims)
    }

    private func validate(claims: [String: Any]) -> Date? {
        let timestamp = now().timeIntervalSince1970
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue,
              timestamp < exp else {
            return nil
        }
        if let nbf = (claims["nbf"] as? NSNumber)?.doubleValue, timestamp < nbf {
            return nil
        }
        guard claims["iss"] as? String == config.issuer else { return nil }
        let auds: [String]
        if let single = claims["aud"] as? String {
            auds = [single]
        } else if let list = claims["aud"] as? [String] {
            auds = list
        } else {
            return nil
        }
        guard auds.contains(config.audTag) else { return nil }
        guard let email = claims["email"] as? String,
              email.lowercased() == config.allowedEmail.lowercased() else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Parsing

    /// Builds a `kid -> SecKey` map from Cloudflare's certs JSON, which carries
    /// PEM certificates under `public_certs`.
    static func parseCerts(_ data: Data) -> [String: SecKey]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let certs = root["public_certs"] as? [[String: Any]] else {
            return nil
        }
        var keys: [String: SecKey] = [:]
        for entry in certs {
            guard let kid = entry["kid"] as? String,
                  let pem = entry["cert"] as? String,
                  let key = publicKey(fromPEMCertificate: pem) else { continue }
            keys[kid] = key
        }
        return keys
    }

    private static func publicKey(fromPEMCertificate pem: String) -> SecKey? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }
        return SecCertificateCopyKey(certificate)
    }

    private static func fetchData(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 { base64 += String(repeating: "=", count: 4 - padding) }
        return Data(base64Encoded: base64)
    }
}
