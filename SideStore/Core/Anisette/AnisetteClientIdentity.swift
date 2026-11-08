//
//  AnisetteClientIdentity.swift
//  SideStore
//
//  Apple's GrandSlam (gsa.apple.com) rejects a sign-in when the identity a client
//  claims in `X-Mme-Client-Info` / `User-Agent` does not match the identity the
//  Anisette ADI data was provisioned for (HTTP 503 first, then -80045 "This
//  action cannot be completed at this time").
//
//  The anisette-v3 protocol publishes the identity that belongs to a server's ADI
//  libraries at `<server>/v3/client_info`. This helper fetches it from the active
//  anisette server (with a compiled-in fallback that matches the public "new mac"
//  servers) so that provisioning, anisette headers and the GSA login all use the
//  same identity. Equivalent to the fix in isideload 0.5.x.
//

import Foundation

public struct AnisetteClientIdentity: Codable, Equatable, Sendable {
    public let clientInfo: String
    public let userAgent: String

    /// Identity published by the "new mac" anisette servers (https://new.ani.sidestore.io,
    /// https://mac-ani.jkcoxson.com, https://ani.iloader.app) at /v3/client_info. The legacy
    /// Android-ADI family (ani.sidestore.io: MacBookPro13,2 / macOS 13.1) is rejected by Apple.
    public static let fallback = AnisetteClientIdentity(
        clientInfo: "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
        userAgent: "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"
    )
}

public actor AnisetteClientIdentityResolver {
    public static let shared = AnisetteClientIdentityResolver()

    private static let cacheDuration: TimeInterval = 60 * 60
    private static let requestTimeout: TimeInterval = 10

    private var cache: [String: (identity: AnisetteClientIdentity, fetchedAt: Date)] = [:]

    /// The server whose ADI identity should be used. For remote anisette this is the
    /// last successfully used server; for on-device anisette (ODA) the libraries come
    /// from the same server family, so the active server's identity applies as well.
    public nonisolated static func activeServerURL() -> URL? {
        let stored = UserDefaults.standard.menuAnisetteURL
        let candidate = stored.isEmpty ? AppConstants.Anisette.Servers.defaultServerURL : stored
        return URL(string: candidate)
    }

    /// Returns the identity to use. Never throws: on any failure it falls back to the
    /// last identity that was successfully fetched, then to the compiled-in default.
    public func resolve(server: URL? = nil) async -> AnisetteClientIdentity {
        let serverURL = server ?? Self.activeServerURL()
        let key = serverURL?.absoluteString ?? ""

        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.cacheDuration {
            return cached.identity
        }

        if let serverURL, let fetched = await Self.fetch(from: serverURL) {
            cache[key] = (fetched, Date())
            UserDefaults.standard.anisetteServerClientInfo = fetched.clientInfo
            UserDefaults.standard.anisetteServerUserAgent = fetched.userAgent
            debugLog("[AnisetteClientIdentity] Using identity from \(serverURL.absoluteString): \(fetched.clientInfo) | \(fetched.userAgent)")
            return fetched
        }

        if let clientInfo = UserDefaults.standard.anisetteServerClientInfo, !clientInfo.isEmpty,
           let userAgent = UserDefaults.standard.anisetteServerUserAgent, !userAgent.isEmpty {
            debugLog("[AnisetteClientIdentity] Server unreachable; reusing last fetched identity: \(clientInfo)")
            return AnisetteClientIdentity(clientInfo: clientInfo, userAgent: userAgent)
        }

        debugLog("[AnisetteClientIdentity] Server unreachable and nothing cached; using built-in fallback identity: \(AnisetteClientIdentity.fallback.clientInfo)")
        return .fallback
    }

    private static func fetch(from serverURL: URL) async -> AnisetteClientIdentity? {
        let url = serverURL.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                debugLog("[AnisetteClientIdentity] \(url.absoluteString) returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("[AnisetteClientIdentity] \(url.absoluteString) did not return a JSON object")
                return nil
            }
            let clientInfo = (json["client_info"] as? String) ?? (json["clientInfo"] as? String) ?? (json["X-Mme-Client-Info"] as? String)
            let userAgent = (json["user_agent"] as? String) ?? (json["userAgent"] as? String) ?? (json["User-Agent"] as? String)
            guard let clientInfo, !clientInfo.isEmpty, let userAgent, !userAgent.isEmpty else {
                debugLog("[AnisetteClientIdentity] \(url.absoluteString) is missing client_info/user_agent")
                return nil
            }
            return AnisetteClientIdentity(clientInfo: clientInfo, userAgent: userAgent)
        } catch {
            debugLog("[AnisetteClientIdentity] Failed to fetch \(url.absoluteString): \(error.localizedDescription)")
            return nil
        }
    }
}
