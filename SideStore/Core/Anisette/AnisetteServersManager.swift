//
//  AnisetteServersManager.swift
//  SideStore
//
//  Created by Magesh K on 28/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

public struct AnisetteServerItem: Codable, Identifiable, Hashable {
    public var id: String { address }
    public var name: String
    public var address: String
    public var isHidden: Bool
    /// servers.json "kind" (see `AppConstants.Anisette.Servers`); nil for user-added or legacy entries.
    public var kind: Int?

    public init(name: String, address: String, isHidden: Bool = false, kind: Int? = nil) {
        self.name = name
        self.address = address
        self.isHidden = isHidden
        self.kind = kind
    }

    /// Legacy (Android-ADI / Windows-ADI) anisette family that Apple's GSA rejects (503 / -80045).
    public var isLegacyFamily: Bool {
        if let kind { return kind != AppConstants.Anisette.Servers.newMacKind }
        return AppConstants.Anisette.Servers.legacyServerAddresses.contains(Self.normalized(address))
    }

    /// Known "new mac" anisette server (kind 2 or one of the built-ins).
    public var isNewMacFamily: Bool {
        if kind == AppConstants.Anisette.Servers.newMacKind { return true }
        return AppConstants.Anisette.Servers.builtInServers.contains { Self.normalized($0.address) == Self.normalized(address) }
    }

    static func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public actor AnisetteServersManager {
    public static let shared = AnisetteServersManager()
    public static let defaultSource = AppConstants.Anisette.Servers.defaultSource

    private var inMemoryServersCache: [AnisetteServerItem]?
    private var isSyncing: Bool = false

    private let userFacingFileURL: URL = {
        let docs = FileManager.default.documentsDirectory
        return docs.appendingPathComponent("anisette-servers.json")
    }()

    private let privateBackupFileURL: URL = {
        let appSupport = FileManager.default.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("SideStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("anisette-servers-backup.json")
    }()

    private let rawImportedBackupFileURL: URL = {
        let appSupport = FileManager.default.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("SideStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("raw-imported-backup.json")
    }()

    private let lastDailySyncKey = "AnisetteServersManager.lastDailySyncTimestamp"
    private let lastDailySyncSuccessKey = "AnisetteServersManager.lastDailySyncSuccess"
    private let lastFailureSyncKey = "AnisetteServersManager.lastFailureSyncTimestamp"

    private init() {}

    // MARK: - Local Persistence & In-Memory Caching

    public func loadLocalServers() -> [AnisetteServerItem] {
        if let cached = inMemoryServersCache {
            return cached
        }

        let fileManager = FileManager.default

        // If user-facing file was deleted by user, restore from private internal mirror backup
        if !fileManager.fileExists(atPath: userFacingFileURL.path) && fileManager.fileExists(atPath: privateBackupFileURL.path) {
            try? fileManager.copyItem(at: privateBackupFileURL, to: userFacingFileURL)
            debugLog("[AnisetteServersManager] User-facing file was missing. Successfully restored from private mirror backup.")
        }

        let targetURL = fileManager.fileExists(atPath: userFacingFileURL.path) ? userFacingFileURL : privateBackupFileURL

        guard fileManager.fileExists(atPath: targetURL.path),
              let data = try? Data(contentsOf: targetURL) else {
            return []
        }

        let decoder = Foundation.JSONDecoder()
        var items: [AnisetteServerItem] = []

        if let decoded = try? decoder.decode([AnisetteServerItem].self, from: data) {
            items = decoded
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in json {
                if let name = dict["name"] as? String, let address = dict["address"] as? String {
                    let isHidden = dict["isHidden"] as? Bool ?? false
                    items.append(AnisetteServerItem(name: name, address: address, isHidden: isHidden, kind: dict["kind"] as? Int))
                }
            }
        }

        inMemoryServersCache = items
        return items
    }

    public func saveLocalServers(_ items: [AnisetteServerItem]) {
        inMemoryServersCache = items

        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(items) {
            // 1. Write to user-facing Documents directory
            try? data.write(to: userFacingFileURL, options: .atomic)
            // 2. Mirror write to internal Application Support backup directory
            try? data.write(to: privateBackupFileURL, options: .atomic)
        }

        let active = items.filter { !$0.isHidden }.map(\.address)
        let currentURL = UserDefaults.standard.menuAnisetteURL
        if !active.contains(currentURL), let first = active.first {
            UserDefaults.standard.menuAnisetteURL = first
        }
    }

    /// Servers used for anisette fetching / failover, in order: "new mac" family first,
    /// then servers of unknown kind (user-added), then anything else. Legacy-family
    /// servers are hidden by default (see `syncWithRemote`), so normally they are not
    /// returned at all. Falls back to the built-in list when nothing is stored yet
    /// (fresh install before the first server-list sync).
    public func getActiveServerURLs() -> [String] {
        let servers = loadLocalServers().filter { !$0.isHidden }
        guard !servers.isEmpty else {
            return AppConstants.Anisette.Servers.builtInServers.map { $0.address }
        }
        let newMac   = servers.filter { $0.isNewMacFamily }
        let unknown  = servers.filter { !$0.isNewMacFamily && !$0.isLegacyFamily }
        let legacy   = servers.filter { !$0.isNewMacFamily && $0.isLegacyFamily }
        return (newMac + unknown + legacy).map(\.address)
    }

    /// One-time migration (0.7.2): Apple now rejects anisette data from the legacy
    /// Android-ADI family (ani.sidestore.io & co.) and from the on-device ADI libraries,
    /// so switch to remote anisette on a "new mac" server, hide the legacy servers, make
    /// the built-in new servers available even before the first list sync, and drop any
    /// adi.pb provisioned under the old family.
    public func migrateToNewAnisetteServersIfNeeded() async {
        guard !UserDefaults.standard.anisetteNewServersMigrationDone else { return }
        debugLog("[AnisetteServersManager] Migrating anisette configuration to the new-mac server family...")

        // Best effort: refresh the catalogue so `kind` is known for every server.
        if !isOfflineMode {
            try? await syncWithRemote()
        }

        var items = loadLocalServers()
        for (index, item) in items.enumerated() where item.isLegacyFamily && !item.isNewMacFamily {
            items[index].isHidden = true
        }
        for builtIn in AppConstants.Anisette.Servers.builtInServers.reversed() {
            if let index = items.firstIndex(where: { AnisetteServerItem.normalized($0.address) == AnisetteServerItem.normalized(builtIn.address) }) {
                items[index].isHidden = false
                if items[index].kind == nil { items[index].kind = AppConstants.Anisette.Servers.newMacKind }
            } else {
                items.insert(AnisetteServerItem(name: builtIn.name, address: builtIn.address, isHidden: false, kind: AppConstants.Anisette.Servers.newMacKind), at: 0)
            }
        }
        saveLocalServers(items)

        let current = UserDefaults.standard.menuAnisetteURL
        let currentItem = items.first { AnisetteServerItem.normalized($0.address) == AnisetteServerItem.normalized(current) }
        if currentItem == nil || currentItem?.isHidden == true || currentItem?.isNewMacFamily != true {
            UserDefaults.standard.menuAnisetteURL = AppConstants.Anisette.Servers.defaultServerURL
        }

        UserDefaults.standard.useOnDeviceAnisette = false

        // adi.pb (Keychain) was provisioned with the old family; force re-provisioning.
        AnisetteConfigManager.shared.anisetteAdiBlob = nil
        UserDefaults.standard.anisetteAdiBlobClientInfo = nil
        UserDefaults.standard.anisetteAdiBlobSource = nil
        UserDefaults.standard.anisetteServerClientInfo = nil
        UserDefaults.standard.anisetteServerUserAgent = nil
        AnisetteDataManager.shared.clearCache()

        UserDefaults.standard.anisetteNewServersMigrationDone = true
        debugLog("[AnisetteServersManager] Migration complete. Active server: \(UserDefaults.standard.menuAnisetteURL), on-device anisette: off.")
    }

    // MARK: - Offline File Mode State Keys

    private let isOfflineModeKey = "AnisetteServersManager.isOfflineMode"
    private let importedFileNameKey = "AnisetteServersManager.importedFileName"

    public var isOfflineMode: Bool {
        get { storedOfflineMode }
        set { storedOfflineMode = newValue }
    }

    public var importedFileName: String? {
        get { storedImportedFileName }
        set { storedImportedFileName = newValue }
    }

    public func importFromFile(url: URL) throws -> [AnisetteServerItem] {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        return try importFromData(data: data, filename: url.lastPathComponent)
    }

    public func importFromData(data: Data, filename: String) throws -> [AnisetteServerItem] {
        var parsedServers: [Server] = []

        let decoder = Foundation.JSONDecoder()
        if let serversObj = try? decoder.decode(AnisetteServerData.self, from: data) {
            parsedServers = serversObj.servers
        } else if let serversArray = try? decoder.decode([Server].self, from: data) {
            parsedServers = serversArray
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in json {
                if let name = dict["name"] as? String, let address = dict["address"] as? String {
                    parsedServers.append(Server(name: name, address: address))
                }
            }
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["servers"] as? [[String: Any]] {
            for dict in list {
                if let name = dict["name"] as? String, let address = dict["address"] as? String {
                    parsedServers.append(Server(name: name, address: address))
                }
            }
        } else {
            throw NSError(domain: "AnisetteServersManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format in imported file."])
        }

        let importedItems = parsedServers.map { AnisetteServerItem(name: $0.name, address: $0.address, isHidden: false) }
        saveLocalServers(importedItems)
        // Save raw imported file backup for Reset feature
        try? data.write(to: rawImportedBackupFileURL, options: .atomic)
        self.isOfflineMode = true
        self.importedFileName = filename
        return importedItems
    }

    public func exportCatalogData(unmodified: Bool = false) -> Data? {
        let itemsToExport: [AnisetteServerItem]

        if unmodified, isOfflineMode,
           FileManager.default.fileExists(atPath: rawImportedBackupFileURL.path),
           let data = try? Data(contentsOf: rawImportedBackupFileURL) {
            let decoder = Foundation.JSONDecoder()
            var parsedServers: [Server] = []
            if let serversObj = try? decoder.decode(AnisetteServerData.self, from: data) {
                parsedServers = serversObj.servers
            } else if let serversArray = try? decoder.decode([Server].self, from: data) {
                parsedServers = serversArray
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for dict in json {
                    if let name = dict["name"] as? String, let address = dict["address"] as? String {
                        parsedServers.append(Server(name: name, address: address))
                    }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = json["servers"] as? [[String: Any]] {
                for dict in list {
                    if let name = dict["name"] as? String, let address = dict["address"] as? String {
                        parsedServers.append(Server(name: name, address: address))
                    }
                }
            }
            itemsToExport = parsedServers.map { AnisetteServerItem(name: $0.name, address: $0.address, isHidden: false) }
        } else {
            itemsToExport = loadLocalServers().filter { !$0.isHidden }
        }

        let exportableServers = itemsToExport.map { Server(name: $0.name, address: $0.address) }
        let catalog = AnisetteServerData(servers: exportableServers)

        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(catalog)
    }

    @discardableResult
    public func resetToOriginalState() async throws -> [AnisetteServerItem] {
        if isOfflineMode {
            guard FileManager.default.fileExists(atPath: rawImportedBackupFileURL.path),
                  let data = try? Data(contentsOf: rawImportedBackupFileURL) else {
                throw NSError(domain: "AnisetteServersManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No raw imported backup found to reset."])
            }

            let decoder = Foundation.JSONDecoder()
            var parsedServers: [Server] = []

            if let serversObj = try? decoder.decode(AnisetteServerData.self, from: data) {
                parsedServers = serversObj.servers
            } else if let serversArray = try? decoder.decode([Server].self, from: data) {
                parsedServers = serversArray
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for dict in json {
                    if let name = dict["name"] as? String, let address = dict["address"] as? String {
                        parsedServers.append(Server(name: name, address: address))
                    }
                }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = json["servers"] as? [[String: Any]] {
                for dict in list {
                    if let name = dict["name"] as? String, let address = dict["address"] as? String {
                        parsedServers.append(Server(name: name, address: address))
                    }
                }
            }

            let rawItems = parsedServers.map { AnisetteServerItem(name: $0.name, address: $0.address, isHidden: false) }
            saveLocalServers(rawItems)
            return rawItems
        } else {
            inMemoryServersCache = nil
            let sourceURL = UserDefaults.standard.menuAnisetteList.isEmpty ? AnisetteServersManager.defaultSource : UserDefaults.standard.menuAnisetteList
            let remoteServers = try await fetchRemoteServers(serverSource: sourceURL)
            let rawItems = remoteServers.map { AnisetteServerItem(name: $0.name, address: $0.address, isHidden: false, kind: $0.kind) }
                .map { item -> AnisetteServerItem in
                    var item = item
                    item.isHidden = item.isLegacyFamily && !item.isNewMacFamily
                    return item
                }
            saveLocalServers(rawItems)
            return rawItems
        }
    }

    public func clearOfflineFileMode() {
        self.isOfflineMode = false
        self.importedFileName = nil
        try? FileManager.default.removeItem(at: rawImportedBackupFileURL)
        UserDefaults.standard.menuAnisetteList = AnisetteServersManager.defaultSource
    }

    // MARK: - Remote Fetching & Public Internet Check

    func fetchRemoteServers(serverSource: String) async throws -> [Server] {
        var aniServers: [Server] = []

        guard let url = URL(string: serverSource) else {
            return aniServers
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let statusName = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
            debugLog("[AnisetteServersManager] Remote fetch failed for URL '\(serverSource)' | Status: HTTP \(statusCode) (\(statusName))")
            throw NSError(domain: "AnisetteServersManager", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Request failed with HTTP status \(statusCode)."])
        }

        let decoder = Foundation.JSONDecoder()
        if let serversObj = try? decoder.decode(AnisetteServerData.self, from: data) {
            aniServers.append(contentsOf: serversObj.servers)
        } else if let serversArray = try? decoder.decode([Server].self, from: data) {
            aniServers.append(contentsOf: serversArray)
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in json {
                if let name = dict["name"] as? String, let address = dict["address"] as? String {
                    aniServers.append(Server(name: name, address: address, kind: dict["kind"] as? Int))
                }
            }
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["servers"] as? [[String: Any]] {
            for dict in list {
                if let name = dict["name"] as? String, let address = dict["address"] as? String {
                    aniServers.append(Server(name: name, address: address, kind: dict["kind"] as? Int))
                }
            }
        } else {
            throw NSError(domain: "AnisetteServersManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format returned from '\(serverSource)'."])
        }

        return aniServers
    }

    public func isPublicInternetAvailable() async -> Bool {
        let url = AppConstants.Anisette.Servers.connectivityCheckURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, (200...399).contains(httpResp.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Smart Syncing

    @discardableResult
    public func syncWithRemote(sourceURLString: String? = nil, forceRemote: Bool = false) async throws -> [AnisetteServerItem] {
        if isOfflineMode && !forceRemote {
            debugLog("[AnisetteServersManager] Background remote sync skipped because user is in Offline File Mode.")
            return loadLocalServers()
        }

        guard !isSyncing else {
            debugLog("[AnisetteServersManager] Sync request ignored (sync operation is already in progress)")
            return loadLocalServers()
        }
        isSyncing = true
        defer { isSyncing = false }

        let sourceURL = sourceURLString ?? (UserDefaults.standard.menuAnisetteList.isEmpty ? AnisetteServersManager.defaultSource : UserDefaults.standard.menuAnisetteList)

        let remoteServers = try await fetchRemoteServers(serverSource: sourceURL)
        let localItems = loadLocalServers()

        var mergedItems: [AnisetteServerItem] = []
        var remainingRemote = remoteServers

        // 1. Preserve local user preferences (ordering and hidden status) for existing servers
        for local in localItems {
            if let remoteIndex = remainingRemote.firstIndex(where: { $0.address == local.address }) {
                let remote = remainingRemote.remove(at: remoteIndex)
                var updated = local
                updated.name = remote.name
                if let kind = remote.kind { updated.kind = kind }
                mergedItems.append(updated)
            }
        }

        // 2. Append newly added remote servers (legacy-family servers arrive hidden:
        //    Apple rejects their anisette data, the user can still unhide them)
        for newRemote in remainingRemote {
            var item = AnisetteServerItem(name: newRemote.name, address: newRemote.address, isHidden: false, kind: newRemote.kind)
            item.isHidden = item.isLegacyFamily && !item.isNewMacFamily
            mergedItems.append(item)
        }

        saveLocalServers(mergedItems)
        return mergedItems
    }

    // MARK: - Triggered Syncs

    /// Kicks off background sync on app boot if > 24 hours ago OR if previous sync failed/interrupted
    public func performDailySyncIfNeeded() async {
        if isOfflineMode {
            return
        }

        let lastSyncTime = lastDailySyncTimestamp
        let lastSuccess = lastDailySyncWasSuccessful
        let now = Date().timeIntervalSince1970

        let twentyFourHours: TimeInterval = 24 * 60 * 60

        if !lastSuccess || (now - lastSyncTime >= twentyFourHours) {
            do {
                try await syncWithRemote()
                lastDailySyncTimestamp = now
                lastDailySyncWasSuccessful = true
                debugLog("[AnisetteServersManager] Daily boot sync completed successfully")
            } catch {
                lastDailySyncWasSuccessful = false
                debugLog("[AnisetteServersManager] Daily boot sync failed for URL '\(UserDefaults.standard.menuAnisetteList)': \(error.localizedDescription)")
            }
        }
    }

    /// Triggered when FetchAnisetteDataOperation encounters no working server.
    /// Rate-limited to once per 15 minutes and ignores duplicate requests while syncing.
    public func syncOnFailureIfNeeded() async {
        if isOfflineMode {
            return
        }

        guard !isSyncing else {
            debugLog("[AnisetteServersManager] Failure-triggered sync skipped (sync operation is already in progress)")
            return
        }

        let lastFailureTime = lastFailureSyncTimestamp
        let now = Date().timeIntervalSince1970
        let fifteenMinutes: TimeInterval = 15 * 60

        guard (now - lastFailureTime >= fifteenMinutes) else {
            debugLog("[AnisetteServersManager] Failure-triggered sync skipped (rate limited to once per 15 mins)")
            return
        }

        lastFailureSyncTimestamp = now
        do {
            try await syncWithRemote()
            debugLog("[AnisetteServersManager] Failure-triggered background sync completed")
        } catch {
            debugLog("[AnisetteServersManager] Failure-triggered background sync failed for URL '\(UserDefaults.standard.menuAnisetteList)': \(error.localizedDescription)")
        }
    }
}

// MARK: - Private AnisetteServersManager Domain Persistence Extension

private extension AnisetteServersManager {
    var storedOfflineMode: Bool {
        get { UserDefaults.standard.bool(forKey: isOfflineModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: isOfflineModeKey) }
    }
    
    var storedImportedFileName: String? {
        get { UserDefaults.standard.string(forKey: importedFileNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: importedFileNameKey) }
    }
    
    var lastDailySyncTimestamp: Double {
        get { UserDefaults.standard.double(forKey: lastDailySyncKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastDailySyncKey) }
    }
    
    var lastDailySyncWasSuccessful: Bool {
        get { UserDefaults.standard.bool(forKey: lastDailySyncSuccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastDailySyncSuccessKey) }
    }
    
    var lastFailureSyncTimestamp: Double {
        get { UserDefaults.standard.double(forKey: lastFailureSyncKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastFailureSyncKey) }
    }
}
