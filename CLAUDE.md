# Shotsy

Native SwiftUI photo organizer for iOS 26+. Read `README.md` (features, owner config, limitations) and `MASCOT.md`
(brand voice, colors, mascot rules) before changing behavior, copy, or visuals. `PROGRESS.md` is the build log.

## Build and test
- `open Shotsy.xcodeproj`, scheme **Shotsy** (includes the StoreKit config and the test target).
- CLI: `xcodebuild -project Shotsy.xcodeproj -scheme Shotsy -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build test`
- Source folders are Xcode synchronized folders: add files anywhere under `Shotsy/`, `Shared/`, `ShotsyTests/`.
  Don't hand-edit `project.pbxproj`; change `tools/generate_project.py` and re-run it.
- Owner values: `Config/Owner.xcconfig` (bundle ID, team) and `Shotsy/Config/OwnerConfig.swift` (product IDs, URLs, `Policy` limits).
- Swift 5 mode with default `MainActor` isolation. Pure logic types are `nonisolated` so tests and background actors can use them. Keep the build at 0 warnings.

## Rules that matter
- Photos is the source of truth. Store asset identifiers only, never media. Never delete except through
  `DeletionService` (revalidate → PhotoKit system confirmation) from the review flow.
- Every review decision goes through `ReviewStore`/`ReviewLedger` (shared free quota, undo, persistence).
- Pro gating reads `PurchaseStore.isPro` (RevenueCat entitlement `shotsy_pro`; the key is in `OwnerConfig`). Never add a local premium flag or a second entitlement system.
  Limits never block undo, corrections, or queued deletions.
- All main scroll containers use `.softAppBar()` (native `.scrollEdgeEffectStyle(.soft, for: .top)`).
- Colors come from semantic tokens in `DesignSystem/Brand.swift` (light + dark). Never white text on lilac.
  One animated mascot per screen; static `ShotsyMascot` elsewhere.
- No private APIs (no KVC `fileSize`). Byte counts shown are measured or labeled estimates.
- No network except Photos/iCloud downloads, the App Store, and RevenueCat (purchases only). Never log recognized text or identifiers.
