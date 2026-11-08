//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        await AnisetteServersManager.shared.migrateToNewAnisetteServersIfNeeded()

        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    /// Remote (anisette-v3) fetch with failover. Unlike SideSign's
    /// `fetchAnisetteDataWithFailover`, the client identity (`X-Mme-Client-Info` /
    /// `User-Agent`) is resolved per server from that server's `/v3/client_info`, so the
    /// provisioning request, the anisette headers and the GSA login always carry the
    /// identity that belongs to the ADI libraries actually used.
    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let ordered: [URL]
        if UserDefaults.standard.disableAnisetteRotation {
            ordered = [servers[startIndex]]
        } else {
            ordered = Array(servers[startIndex...]) + Array(servers[..<startIndex])
        }

        let provider = SideSign.AnisetteDataManager.shared
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()

        var lastError: Error?
        for (attempt, server) in ordered.enumerated() {
            debugLog("[AnisetteProvider] Attempting server [\(attempt + 1)/\(ordered.count)]: \(server.absoluteString)")

            // Identity for this server (also discards a stale adi.pb if identity/source changed).
            let headers = await AnisetteConfigManager.shared.makeRequestHeaders(server: server, source: server.absoluteString)
            let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }

            do {
                let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteData(
                    mode: .remote(server: server),
                    identifier: identifier,
                    existingAdiBlob: existingBlob,
                    headers: headers,
                    onError: { error in
                        if let anisetteError = error as? SideSign.AnisetteError,
                           case .outdatedV1Server(let serverURL, _) = anisetteError {
                            if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                                return true
                            }
                            if let handler = handler {
                                let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                                if shouldContinue {
                                    UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                                }
                                return shouldContinue
                            }
                        }
                        return false
                    }
                )

                UserDefaults.standard.menuAnisetteURL = server.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(server.absoluteString) (client info: \(anisetteData.clientInfo))")

                if let freshBlob = newAdiBlob {
                    AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
                    AnisetteConfigManager.shared.recordProvisionedIdentity(clientInfo: anisetteData.clientInfo, source: server.absoluteString)
                }

                return anisetteData
            } catch {
                lastError = error
                debugLog("[AnisetteProvider] Server [\(attempt + 1)/\(ordered.count)] '\(server.absoluteString)' failed: \(error.localizedDescription)")
            }
        }

        debugLog("[AnisetteProvider] All \(ordered.count) servers failed. Last error: \(lastError?.localizedDescription ?? "unknown")")
        throw lastError ?? AnisetteError.allServersFailed
    }
}
