//
//  SideSignConfigManager.swift
//  SideStore
//
//  Created by Magesh K on 11/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

public actor SideSignConfigManager {
    public static let shared = SideSignConfigManager()
    
    private nonisolated var configFileURL: URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryDirectory.appendingPathComponent("sidesign-config.json")
    }
    
    public func loadConfig() -> SideSignHeaders {
        if let data = try? Data(contentsOf: configFileURL),
           let config = try? Foundation.JSONDecoder().decode(SideSignHeaders.self, from: data) {
            DeveloperPortal.shared.customHeaders = config
            return config
        }
        let defaultConfig = Self.defaultHeaders()
        DeveloperPortal.shared.customHeaders = defaultConfig
        return defaultConfig
    }

    /// Default SideSign headers. The GrandSlam `User-Agent` follows the anisette client
    /// identity (see `AnisetteClientIdentity`): Apple rejects a GSA login whose client
    /// identity differs from the one the anisette/ADI data was provisioned with.
    public nonisolated static func defaultHeaders(anisetteIdentity: AnisetteClientIdentity? = nil) -> SideSignHeaders {
        var headers = SideSignHeaders()
        guard UserDefaults.standard.useAnisetteServerClientInfo else { return headers }
        let userAgent = anisetteIdentity?.userAgent
            ?? UserDefaults.standard.anisetteServerUserAgent
            ?? AnisetteClientIdentity.fallback.userAgent
        if !userAgent.isEmpty {
            headers.grandSlam.userAgent = userAgent
        }
        return headers
    }

    public nonisolated func applyConfigToDeveloperPortal(anisetteIdentity: AnisetteClientIdentity? = nil) {
        if let data = try? Data(contentsOf: configFileURL),
           let config = try? Foundation.JSONDecoder().decode(SideSignHeaders.self, from: data) {
            DeveloperPortal.shared.customHeaders = config
        } else {
            DeveloperPortal.shared.customHeaders = Self.defaultHeaders(anisetteIdentity: anisetteIdentity)
        }
    }
    
    public func saveConfig(_ config: SideSignHeaders) {
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
        DeveloperPortal.shared.customHeaders = config
    }
    
    public func importFromFile(url: URL) throws -> SideSignHeaders {
        let data = try Data(contentsOf: url)
        let config = try Foundation.JSONDecoder().decode(SideSignHeaders.self, from: data)
        saveConfig(config)
        return config
    }
    
    public func exportConfigData() -> Data? {
        let config = loadConfig()
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(config)
    }
    
    @discardableResult
    public nonisolated func resetToDefaults() -> SideSignHeaders {
        deleteConfigFile()
        let defaultConfig = Self.defaultHeaders()
        DeveloperPortal.shared.customHeaders = defaultConfig
        return defaultConfig
    }
    
    public nonisolated func deleteConfigFile() {
        try? FileManager.default.removeItem(at: configFileURL)
    }
    
    public nonisolated func hasConfigFile() -> Bool {
        return FileManager.default.fileExists(atPath: configFileURL.path)
    }
}
