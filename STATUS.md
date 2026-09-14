# STATUS — sidestore (Vision Pro fork)

Branch: `visionos-support` (fork remote: rebelancap/SideStore; `origin` = SideStore/SideStore upstream)
Last updated: 2026-09-13 (third round)

## Current state

`visionos-support` is rebased onto upstream `origin/develop` (57805920, marketing
version **0.7.0**) and carries four Vision Pro commits. A fresh unsigned visionOS
IPA is built and packaged at **`build/SideStore-visionOS.ipa`** (25.4 MB, bundle id
`com.SideStore.SideStore`, CFBundleShortVersionString `0.7.0`, CFBundleVersion
`0700`, arm64 only, `UIRequiredDeviceCapabilities = arm64`, no app extensions,
LC_BUILD_VERSION platform 2 / iOS SDK 27.0 — the iPad-compat build the Vision Pro
runs, same shape as the shipped `visionos-0.6.4` asset).

The Apple GSA 503 problem is fixed upstream and inherited: the anisette default
`client_info` now resolves to `<MacBookPro18,3> <macOS;26.6;25F84>
<com.apple.AuthKit/1 (com.apple.akd/1.0)>` via AnisetteKit, and nothing in our
fork re-introduces the `com.apple.dt.Xcode` string. The old
`FetchAnisetteDataOperation.swift` that took `client_info` from the server's
`/v3/client_info` no longer exists; server headers are now only a validation probe
plus an explicit user override in Settings ▸ Advanced ▸ Anisette.

Submodules: upstream replaced `Dependencies/AltSign` + `Dependencies/em_proxy`
with `Dependencies/SideSign`. Both live submodules sit on local
`visionos-support` branches that are **not pushed anywhere**:
- `Dependencies/SideSign` @ `fb1a307` (off SideStore/SideSign `df2b8e4`)
- `Dependencies/minimuxer` @ `eb67fe9` (off SideStore/minimuxer `98c3c79`)

## Last round (2026-09-13, round 3) — blank Home View icon: no build regression

Symptom: the 0.7.0 build runs fine on the headset but its Home View icon is blank.

Diagnosis: **the 0.7.0 IPA's icon payload is byte-identical to the shipped
`visionos-0.6.4` IPA that renders an icon.** Evidence (both IPAs unpacked and
compared):

- `Info.plist`: `CFBundleIcons`, `CFBundleIcons~ipad` (primary + all 11
  `CFBundleAlternateIcons`), `CFBundleIconFiles` (`AppIcon60x60`,
  `AppIcon76x76`), `CFBundleIconName = AppIcon` and
  `NSAppIconComplementingColorNames` (`GradientTop`/`GradientBottom`) are
  identical. The full plist diff is only: UDID, `DTPlatformBuild` (Xcode beta),
  version strings, a `localdevvpn` URL scheme, extra Bonjour services, the local
  network usage string and the `processing` background mode. `UIDeviceFamily`
  `[1, 2]`, `MinimumOSVersion 15.0`, `UIRequiredDeviceCapabilities [arm64]` and
  `CFBundleSupportedPlatforms [iPhoneOS]` match, so neither our arm64 edit nor
  the PlugIns strip touched icon keys.
- `xcrun assetutil --info Assets.car`: same 30 AppIcon renditions (phone + pad +
  1024 marketing, same byte sizes), same 11 alternate icons, both colour assets
  present, same CAR header (StorageVersion 17, Platform ios 15.0).
- Loose `AppIcon60x60@2x.png` / `AppIcon76x76@2x~ipad.png`: `cmp`-identical, and
  identical between `build/SideStore-visionOS.xcarchive` and the packaged IPA, so
  the strip/zip step drops nothing.
- Repo: `git diff 0.6.4 HEAD` over `AltStore/Resources/Icons.xcassets/AppIcon.appiconset`
  is empty, and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` /
  `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` are unchanged. No
  Icon Composer `.icon` bundle exists anywhere upstream.
- Device side: installd's own record of the installed app (iloader log,
  `com.SideStore.SideStore.57G8J46Z2T`) lists every icon key, and the install
  uploaded all 142 files of the signed bundle over AFC, so nothing was dropped in
  transit.

**No repo fix was warranted — there is no icon regression to fix.** The blank icon
is device-side (visionOS icon cache for the bundle id, refreshed in place across
July's 0.6.4 install and today's 0.7.0 installs).

Actions taken this round: re-signed and reinstalled the same
`build/SideStore-visionOS.ipa` through iloader 2.3.4 ("InstallComplete",
"Operation completed", no keychain prompt), re-placed the pairing file
("Pairing file placed successfully"), and **deleted the stale July
`rp_pairing_file.plist`** from the headset
(`afcclient --container com.SideStore.SideStore.57G8J46Z2T rm
/Documents/rp_pairing_file.plist`; the follow-up `ls` shows only
`ALTPairingFile.mobiledevicepairing`, `DMG`, `ConsoleLogs`,
`anisette-servers.json`). The archive at `build/SideStore-visionOS.xcarchive` is
untouched for the LiveContainer combo build.

Still open: Austin must look at the Home View. If the icon is still blank after
this reinstall, the remaining lever is a **delete + fresh install** of SideStore
on the headset (that is what rebuilds visionOS's icon cache entry; it also wipes
the app's data container, so sources/pairing have to be re-placed) — his call.

## Previous round (2026-09-13, round 2) — ".rppairing UDID not found" fixed

Symptom: on the headset the 0.7.0 build signed in to the Apple ID fine (503 gone),
then device registration died with `.rppairing UDID not found`.

Root cause (proved from the device's own console log, pulled over USB with
`afcclient --container com.SideStore.SideStore.57G8J46Z2T get
/Documents/ConsoleLogs/console_20260913_190216_780.log`):

    [IdeviceGateway] ensureRPConnection() tunnel_create_rppairing failed with code: 1,
      message: Socket(Os { code: 54, kind: ConnectionReset, ... })
    [IdeviceGateway] fetchUDID() ensureRPConnection failed: The pairing file is invalid

SideStore's Documents held TWO pairing files: a stale `rp_pairing_file.plist`
(501 B, mtime 2026-07-26, from the July vision-sideload run) and the
`ALTPairingFile.mobiledevicepairing` iloader placed today (9771 B). The fresh one is
a MERGED plist — lockdown keys PLUS the RemotePairing keys
(identifier/public_key/private_key/alt_irk) — so it parses as `.rppairing`. Our
re-applied preference commit returned `rp_pairing_file.plist` unconditionally before
ever looking at it, so SideStore pair-verified with the dead July pairing, the headset
reset the connection, `IdeviceGateway.fetchUDID()` returned nil
(`Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift:636`), and
`MinimuxerImpl.isReady()` failed at `Sources/MinimuxerImpl.swift:221`. Nothing in
minimuxer was wrong — upstream merely started calling `fetchUDID()` in rppairing mode
(0.6.4's `isReady` skipped it for RP, which is why this never bit before).

Fix (`f559ca42`, SideStore proper, no submodule change):
`SideStore/Core/Pairing/PairingFileManager.swift` — `fetchRemotePairingFile()` replaced
by `bestPairingFileInDocuments()`, which ranks every candidate (ALTPairingFile,
rp_pairing_file.plist, `*_rp.plist`) by "parses as .rppairing" first and then by newest
mtime. A stale RP pairing can no longer shadow a freshly written one.

Rebuilt and reinstalled: archive + strip PlugIns + zip as before →
`build/SideStore-visionOS.ipa` (25.4 MB, 0.7.0 / 0700, no `.appex`), signed and
installed on the headset through the running iloader 2.3.4 ("InstallComplete",
"Sign & Install App — Operation completed"), then Manage Pairing File ▸ Place for
`com.SideStore.SideStore.57G8J46Z2T` (ALTPairingFile mtime refreshed on device). No
keychain prompt appeared.

## Earlier round (2026-09-13) — upstream sync + IPA rebuild

- Backup branch `backup/visionos-support-pre-sync-2026-09-13` created (nothing was
  stashable; the only dirt was submodule pointers). Old AltSign vision commit
  `6a22bc1` is safe on rebelancap/AltSign branch `visionos-support`, and its patch
  text is in this round's commit messages.
- Rebased 6 commits onto `origin/develop` (759 commits ahead). **2 applied**
  (Info.plist `armv7`→`arm64`; show every app on the source page — conflict was
  just upstream's `RSTArrayCollectionViewPrefetchingDataSource` →
  `ArrayCollectionViewPrefetchingDataSource` rename). **4 hit modify/delete** and
  were skipped, then re-applied by hand at their new homes in `7e5f412c`:
  - `AuthenticationOperation.fetchDevices(types:)` widening — **dropped as
    redundant**, upstream's `DeviceRegistrationFlow` already fetches `.all`.
  - deviceAlreadyRegistered tolerance → `SideStore/Core/Auth/Flows/DeviceRegistrationFlow.swift`,
    now catching `DeveloperPortalError.deviceAlreadyRegistered`.
  - rp_pairing_file preference → `SideStore/Core/Pairing/PairingFileManager.fetchPairingFile()`,
    generalised to `rp_pairing_file.plist` then newest `*_rp.plist` (upstream's
    Wireless Pair writes both names and nothing read them back).
  - DatabaseManager app-group-accessibility guard → `AltStore/Core/Model/DatabaseManager/`.
  - minimuxer submodule bump — the superproject commit was skipped; instead the
    minimuxer branch itself was rebased (below).
- `Dependencies/minimuxer`: our 2 commits rebased onto upstream `98c3c79`. The
  visionOS-DDI commit survived; **the install-error-surfacing commit `13f8e73` was
  dropped as redundant** (upstream now appends the FFI message itself via
  `getErrorMessage(from:)`). `d06aa661` adapts `Mounter.isVisionDevice()` to
  upstream's new `DeviceGatewayAPI` protocol (it can no longer reach
  `IdeviceGateway.shared`; now reads ProductType through the injected gateway).
- `Dependencies/SideSign` (`fb1a307`): SideSign already models `.visionPro`
  thoroughly (DeviceType, UIDeviceFamily 7, ProfileType, subPlatform "visionOS"),
  so most of the AltSign patch is upstream. Two gaps closed: `Device.init(from:)`
  now maps deviceClass `realitydevice`/`visionpro`/`xros` (Apple's actual string
  for a VP; it used to parse to `.none`), and `registerDevice` sends
  `DTDK_Platform=ios` for `.visionPro`.
- Archive + package: Xcode-beta 27.0, `xcodebuild archive -scheme SideStore -sdk
  iphoneos -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO -archivePath build/SideStore-visionOS.xcarchive`, then
  `rm -rf Payload/SideStore.app/PlugIns` (must strip `AltWidgetExtension.appex` —
  a sideload can't provision it) and zip. Verified no `.appex` in the IPA.
- Disk: deleted the stale 107 MB `SideStore.xcarchive` and 24 MB `SideStore.ipa`
  left at repo root by the July builds; all output now lives in `build/`.

## Published (2026-09-14)

Published 2026-09-14: iloader 2.3.5 (notarized) on rebelancap/iloader release `visionos`; SideStore 0.7.0 on rebelancap/SideStore release `visionos-0.7.0` (iloader URL updated); LC combo on rebelancap/LiveContainer release `visionos`. Branch visionos-tunnel force-pushed (rebased); backup branch pushed. Verified on headset: sign-in, registration, app update, icon after reboot.

## Next steps

1. **Austin retests in the headset** (this is the open item):
   open SideStore ▸ Settings ▸ Advanced ▸ Anisette ▸ Reset ADI, then sign in with the
   Apple ID. Sign-in and the device-registration step right after it should both pass.
   If registration still fails, pull the newest
   `/Documents/ConsoleLogs/console_*.log` off the device (afcclient recipe above) and
   look for `ensureRPConnection()`/`fetchUDID()` lines.
2. ~~Delete the dead `rp_pairing_file.plist` from the headset~~ — done this
   round (round 3), confirmed by `afcclient ... ls /Documents`.
3. Austin picks the GitHub release tag. Proposal: **`visionos-0.7.0`**. Nothing pushed.
4. On-headset acceptance run before any publish (JIT/DDI): install
   `build/SideStore-visionOS.ipa` on the Vision Pro (iloader / vision-sideload),
   then **reset adi.pb** (Settings ▸ Advanced ▸ Anisette ▸ Reset ADI) — upstream
   requires it after the akd client-info change — and sign in with the Apple ID.
   Watch for: sign-in succeeding (no 503, no "device already registered"), the
   wireless RP pairing file being picked up on boot, and JIT finding the xrOS DDI.
5. If sign-in works, decide whether to also refresh the LiveContainer-embedded
   SideStore build (`rebelancap/LiveContainer` release `sidestore-visionos-dep`),
   which is a separate 0.6.4-era IPA pinned by iloader and is still on the Xcode
   client-info default.
6. Push `visionos-support` to rebelancap/SideStore and push the two submodule
   branches somewhere durable (a rebelancap/SideSign fork and the existing
   rebelancap/minimuxer) — the gitlinks currently point at local-only commits, so
   a fresh clone of this branch cannot build.
7. Optional upstream PRs: the four re-applied fixes are all generic, not
   VP-specific hacks; the PairingFileManager one in particular is a plain upstream
   bug (Wireless Pair writes a file nothing reads).

## Open questions

- **Release tag and timing** — Austin's call, always. Default if unanswered:
  nothing is tagged or published; the IPA just sits at
  `build/SideStore-visionOS.ipa`.
- **`Constants.GrandSlam.userAgent` in SideSign still reads
  `AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)`.** That is the GSA
  `User-Agent`, not the `X-MMe-Client-Info` header Apple 503s on, and upstream
  left it as-is deliberately. Default: leave it alone; revisit only if sign-in
  still 503s on the headset.
- **Where should the SideSign visionOS commit live long-term?** Default: fork
  SideStore/SideSign to rebelancap and push `visionos-support` there, then repoint
  `.gitmodules`, at the same time as step 4 above.

## Live claims

None. Session closed cleanly 2026-09-14: nothing booted, no agents running, tree clean.
