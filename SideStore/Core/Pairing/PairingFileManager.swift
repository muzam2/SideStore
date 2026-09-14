//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import UniformTypeIdentifiers
import MinimuxerCommon

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()
    static let pairingFileName = AppConstants.Pairing.fileName

    private var completion: ((URL?) -> Void)?

    nonisolated var pairingUDID: String? {
        guard let contents = fetchPairingFile() else {
            debugLog("[PairingFile] pairingUDID: fetchPairingFile() returned nil")
            return nil
        }
        do {
            let pairing = try PairingFileParser.parse(content: contents)
            guard let lockdown = pairing as? LockdownPairingFile else {
                debugLog("[PairingFile] pairingUDID: Remote Pairing files do not contain a hardware UDID")
                return nil
            }
            return lockdown.udid
        } catch {
            debugLog("[PairingFile] pairingUDID: failed to parse pairing file: \(error)")
            return nil
        }
    }

    nonisolated func fetchPairingFile() -> String? {
        let fm = FileManager.default

        // Prefer a RemotePairing capable file when present. On iOS-17+/visionOS the
        // install and JIT services live behind the RSD tunnel, which requires an RP
        // pairing; a classic lockdown-only pairing can reach basic services only.
        // WirelessPairViewModel writes `rp_pairing_file.plist` (or
        // `<DeviceName>_rp.plist`) but nothing ever read them back, so a successful
        // wireless pair was never used on the next boot.
        //
        // RP-ness alone is not enough to choose, though: `ALTPairingFile` is what every
        // external pairing tool (re-)writes, and on a Vision Pro iloader writes a MERGED
        // plist there that carries the RP keys too — so it is usually the freshest RP
        // pairing on the device. A stale `rp_pairing_file.plist` left behind by an older
        // pairing run is rejected by the device at pair-verify time
        // (`tunnel_create_rppairing` -> "Connection reset by peer"), which surfaced as
        // ".rppairing UDID not found" during sign-in. So rank RP files ahead of lockdown
        // files, but break ties by modification date and use the newest.
        if let best = bestPairingFileInDocuments() {
            return best
        }
        if let url = Bundle.main.url(forResource: AppConstants.Pairing.bundleResourceName, withExtension: AppConstants.Pairing.fileExtension),
           fm.fileExists(atPath: url.path),
           let data = fm.contents(atPath: url.path),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty, 
           !UserDefaults.standard.isPairingReset 
        { 
            return contents 
        }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: AppConstants.Pairing.bundleResourceName) as? String,
           !plistString.isEmpty, 
           !plistString.contains(AppConstants.Pairing.placeholderString), 
           !UserDefaults.standard.isPairingReset 
        { 
            return plistString 
        }
        return nil
    }

    /// Picks the best pairing file sitting in Documents: `ALTPairingFile`, the
    /// Wireless-Pair `rp_pairing_file.plist`, and any `<DeviceName>_rp.plist`.
    /// Ranked by "parses as a RemotePairing file" first, then by newest on disk, so a
    /// stale RP pairing can never shadow a freshly written one.
    nonisolated func bestPairingFileInDocuments() -> String? {
        let fm = FileManager.default
        let docs = fm.documentsDirectory

        var urls: [URL] = [
            docs.appendingPathComponent(Self.pairingFileName),
            docs.appendingPathComponent("rp_pairing_file.plist"),
        ]
        if let entries = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: entries.filter { $0.lastPathComponent.hasSuffix("_rp.plist") })
        }

        var best: (contents: String, isRP: Bool, date: Date)?
        var seen = Set<String>()
        for url in urls {
            guard seen.insert(url.standardizedFileURL.path).inserted,
                  fm.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url), !contents.isEmpty
            else { continue }

            let isRP = ((try? PairingFileParser.parse(content: contents))?.mode == .rppairing)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

            let wins: Bool
            if let current = best {
                wins = (isRP != current.isRP) ? isRP : (date > current.date)
            } else {
                wins = true
            }
            if wins {
                best = (contents, isRP, date)
                debugLog("[PairingFile] candidate '\(url.lastPathComponent)' (rppairing: \(isRP), modified: \(date)) is now preferred")
            }
        }
        return best?.contents
    }

    func savePairingFile(contents: String) throws {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent(Self.pairingFileName)
        if fm.fileExists(atPath: documentsPath.path) {
            try? fm.removeItem(at: documentsPath)
        }
        try contents.write(to: documentsPath, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Successfully copied and saved pairing file to: \(documentsPath.path)")
        UserDefaults.standard.isPairingReset = false
    }
}

#if !os(tvOS)
extension PairingFileManager: UIDocumentPickerDelegate {
    @MainActor
    func presentPairingFileAlert(on vc: UIViewController, isRetry: Bool, completion: ((URL?) -> Void)? = nil) {
        self.completion = { url in
            completion?(url)
            self.completion = nil
        }
        let title = isRetry ? NSLocalizedString("Invalid Pairing File", comment: "") : NSLocalizedString("Pairing File", comment: "")
        let message = isRetry
            ? NSLocalizedString("The selected pairing file is invalid or not usable. Please select a valid pairing file.", comment: "")
            : NSLocalizedString("Select the pairing file or select \"Help\" for help.", comment: "")
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Help", comment: ""), style: .default) { _ in
            UIApplication.shared.open(AppConstants.URLs.pairingDocumentation)
            if completion == nil {
                sleep(2); exit(0)
            } else {
                completion?(nil)
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Select File", comment: ""), style: .default) { _ in
            var types = UTType.types(tag: "plist", tagClass: .filenameExtension, conformingTo: nil)
            types.append(contentsOf: UTType.types(tag: AppConstants.Pairing.fileExtension, tagClass: .filenameExtension, conformingTo: .data))
            types.append(.xml)
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            vc.present(picker, animated: true)
            UserDefaults.standard.isPairingReset = false
        })
        
        let cancelTitle = isRetry ? NSLocalizedString("Skip", comment: "") : NSLocalizedString("Cancel", comment: "")
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            if completion == nil {
                self.showPairingWarningAndProceed(on: vc)
            } else {
                completion?(nil)
            }
        })
        vc.present(alert, animated: true)
    }
    
    func showPairingWarningAndProceed(on vc: UIViewController) {
        let warningAlert = UIAlertController(
            title: "⚠️ " + NSLocalizedString("Pairing Required", comment: ""),
            message: NSLocalizedString("Without a valid pairing file, operations that require a pairing file (such as installing, refreshing, or resigning apps) will not function.", comment: ""),
            preferredStyle: .alert
        )
        warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        vc.present(warningAlert, animated: true)
    }

    func importPairingFile(presentingVC: UIViewController, title: String, message: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.presentPairingFileAlert(on: presentingVC, isRetry: false) { url in
                    if let url = url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: OperationError.invalidPairingFile(reason: "URL is nil"))
                    }
                }
            }
        }
    }

    @MainActor
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let url = urls[0]
        let isSecuredURL = url.startAccessingSecurityScopedResource() == true
        defer {
            if (isSecuredURL) {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            debugLog("[PairingFile] User picked pairing file from: \(url.path)")
            let data = try Data(contentsOf: url)
            guard let pairingString = String(data: data, encoding: .utf8) else {
                debugLog("[PairingFile] Unable to read pairing file")
                self.completion?(nil)
                return
            }
            
            // Delegate file operations to the main class
            try savePairingFile(contents: pairingString)
            self.completion?(url)
        } catch {
            debugLog("[PairingFile] Error importing pairing file: \(error)")
            self.completion?(nil)
        }
        
        controller.dismiss(animated: true, completion: nil)
    }

    @MainActor
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.completion?(nil)
    }
}
#else
extension PairingFileManager {
    @MainActor
    func presentPairingFileAlert(on vc: UIViewController, isRetry: Bool, completion: ((URL?) -> Void)? = nil) {
        self.completion = { url in
            completion?(url)
            self.completion = nil
        }

        let title = isRetry ? NSLocalizedString("Invalid Pairing File", comment: "") : NSLocalizedString("Pairing File Required", comment: "")
        TVWebFileTransferManager.shared.startImport(
            acceptedExtensions: ["mobiledevicepairing", "plist", "xml"],
            title: title,
            presentingVC: vc
        ) { [weak self] tempURL in
            guard let self = self else { return }
            guard let tempURL = tempURL,
                  let data = try? Data(contentsOf: tempURL),
                  let pairingString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                if let completion = self.completion {
                    completion(nil)
                } else {
                    self.showPairingWarningAndProceed(on: vc)
                }
                return
            }

            do {
                try self.savePairingFile(contents: pairingString)
                let documentsPath = FileManager.default.documentsDirectory.appendingPathComponent(Self.pairingFileName)
                if let completion = self.completion {
                    completion(documentsPath)
                } else {
                    Task.detached {
                        do {
                            try await AppBootManager.shared.startMinimuxer(pairingFile: pairingString)
                        } catch {
                            debugLog("[PairingFile] startMinimuxer failed: \(error)")
                        }
                    }
                }
            } catch {
                debugLog("[PairingFile] Failed to save uploaded pairing file: \(error)")
                if let completion = self.completion {
                    completion(nil)
                }
            }
        }
    }

    func showPairingWarningAndProceed(on vc: UIViewController) {
        let warningAlert = UIAlertController(
            title: "⚠️ " + NSLocalizedString("Pairing Required", comment: ""),
            message: NSLocalizedString("Without a valid pairing file, operations that require a pairing file (such as installing, refreshing, or resigning apps) will not function.", comment: ""),
            preferredStyle: .alert
        )
        warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        vc.present(warningAlert, animated: true)
    }

    func importPairingFile(presentingVC: UIViewController, title: String, message: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.presentPairingFileAlert(on: presentingVC, isRetry: false) { url in
                    if let url = url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: OperationError.invalidPairingFile(reason: "URL is nil"))
                    }
                }
            }
        }
    }
}
#endif
