# STATUS — sidestore (Vision Pro fork)

Branch: `visionos-support` (fork remote: rebelancap/SideStore; `origin` = SideStore/SideStore upstream)
Last updated: 2026-09-13

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

## Last round (2026-09-13) — upstream sync + IPA rebuild

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

## Next steps

1. Austin picks the GitHub release tag. Proposal: **`visionos-0.7.0`** (upstream
   marketing version is 0.7.0; the last one was `visionos-0.6.4`). Nothing was
   pushed and no release was touched this round.
2. On-headset acceptance run before any publish: install
   `build/SideStore-visionOS.ipa` on the Vision Pro (iloader / vision-sideload),
   then **reset adi.pb** (Settings ▸ Advanced ▸ Anisette ▸ Reset ADI) — upstream
   requires it after the akd client-info change — and sign in with the Apple ID.
   Watch for: sign-in succeeding (no 503, no "device already registered"), the
   wireless RP pairing file being picked up on boot, and JIT finding the xrOS DDI.
3. If sign-in works, decide whether to also refresh the LiveContainer-embedded
   SideStore build (`rebelancap/LiveContainer` release `sidestore-visionos-dep`),
   which is a separate 0.6.4-era IPA pinned by iloader and is still on the Xcode
   client-info default.
4. Push `visionos-support` to rebelancap/SideStore and push the two submodule
   branches somewhere durable (a rebelancap/SideSign fork and the existing
   rebelancap/minimuxer) — the gitlinks currently point at local-only commits, so
   a fresh clone of this branch cannot build.
5. Optional upstream PRs: the four re-applied fixes are all generic, not
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

- No simulator lane held; no devices booted (nothing was launched this round —
  archive-only build).
- No background agents running.
- Working tree clean on `visionos-support`; both submodules clean on their local
  `visionos-support` branches (unpushed — see Next steps 4).
- Backups: `backup/visionos-support-pre-sync-2026-09-13` (superproject),
  `backup/vision-2026-09-13` in `Dependencies/minimuxer`.
