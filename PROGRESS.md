# Shotsy build log

Working record for the production brief (Shotsy-Claude-Production-Prompt-2.md). Newest first.

## Status
- [x] Project: app + widget extension + tests targets, Owner.xcconfig, entitlements (App Group), StoreKit config, shared scheme (`tools/generate_project.py`)
- [x] Core: SwiftData schema v1 + migration plan (main store + backup-excluded derived store), PhotoKit services, review engine (quota/undo), StoreKit 2 entitlements, analysis (feature prints, blur, OCR, video sizes), screenshot classifier, smart rules, On This Day, People (removed 2026-10-01), compression, reminders, widget snapshot
- [x] UI: onboarding, Clean, sort session, review deletions, categories, Screenshot Inbox, On This Day, Library, preview, Albums, Smart Collections, compression, Settings, paywall
- [x] Widget UI (small/medium), notification deep links
- [x] String Catalog plurals (English), privacy manifest
- [x] 66 tests / 13 suites passing; 0 warnings; README, APP_REVIEW_NOTES
- [ ] Owner values (bundle ID, team, App Group, product IDs, legal URLs)
- [ ] Device testing, iOS 27, StoreKit end-to-end, VoiceOver/Dynamic Type passes

## Decisions
- People (face tagging) removed on 2026-10-01 (owner decision). Shotsy no longer detects, groups, or stores faces.
- iOS 27 SDK/runtime not installed → iOS 27 builds/tests unverified.
- Byte sizes: no private KVC. Videos use the local file URL size; photo sizes aren't shown.

## Log
- 2026-10-01: People removed (owner decision): face detection, PeopleStore/worker, FaceGrouper/FaceEmbedder, People screens, Library People row/person filter/search, Smart Collection person rules, Settings → People, paywall reason, `freePeoplePreviewPhotos`, People tests, and face mentions in onboarding, privacy summary, docs, and App Store text. SwiftData `SchemaV2` drops `PersonRecord`/`FaceRecord` via a lightweight V1 → V2 stage (`SchemaV1` kept frozen; derived store can be recreated as a fallback); leftover `faces.*` index rows and the `people` default are removed at launch. Saved 1.0 Smart Collections drop person rules instead of failing to decode. Migration test added. 56 unused strings removed from the catalog.
- 2026-10-01 (later): Photo Info sheet (measured size, EXIF, albums) + HEIC→JPG copy; swipe up to add to album; Clean tab month cards with fanned previews; Bursts, Screen Recordings, Slo-mo categories; "Free up about X" (videos measured, photos estimated). Burst batch marking is Pro like Similar. Full-bleed preview with Liquid Glass chrome and tap-to-hide. Perf pass: Clean tab pauses during sorting, month sections cached, summary PhotoKit reads off main, incremental decision sync with O(1) pendingCount, deck drag isolated in CardDeck, lazy rows in categories. 109 tests.
- 2026-10-01: App Review rejection (5.1.1 "Connect Photos" button, 2.1 paywall showed RevenueCat error: StoreKit returned no products on iPad review; ASC/RevenueCat config verified correct). Permission buttons now "Continue"; paywall retries and shows a short message. Sync: no library re-fetch on foreground, analysis only for inserted/edited assets, no restart on launch entitlement, time-throttled summaries, failed items retried once per launch, new Settings → Sync (Scan automatically, Pause in Low Power Mode, Scan Now). Screens load off main with debounced reloads. Fixed crash on reminder tap (async UNUserNotificationCenter delegate). Review: Unmark unselected / Unmark All / post-delete choice. People: multi-select tagging, name reuse. Favorites flip instantly via pending state and don't trigger scans.
- 2026-09-28: Full build. Found & fixed: non-square grid cells; soft card image (exact-size requests for large views);
  Vision fails in simulator → failed items now retry next scan; similarity grouping 32 s → 0.12 s for 20k (vDSP);
  all Swift 6 concurrency warnings resolved.
- 2026-09-28: Owner switched purchases to RevenueCat (5.91.0) and prices to $1.99/week, $19.99 lifetime. StoreKit-only entitlement code replaced; API key pending.
- 2026-09-28: RevenueCat configured: App Store products imported, attached to entitlement shotsy_pro, added to offering default ($rc_weekly, $rc_lifetime). Public SDK key still to be pasted by owner.
- 2026-09-28: RevenueCat key added; paywall verified loading $19.99 lifetime / $1.99 week from the live offering in the simulator. Removed Terms link from onboarding (owner request; still in Settings and paywall).
- 2026-09-28: Paywall redesign (research-based): personalized subhead with real library count, 4-item checklist, Best value lifetime with computed price comparison, sticky price CTA, one-line reassurance ('Cancel anytime in your Apple Account'), compact Restore/Terms footer, entrance animation + selection haptics.
- 2026-09-28: Localized into 12 languages (ru, es, pt-BR, fr, de, it, ja, ko, zh-Hans, zh-Hant, id, vi); verified ru and ja in simulator. Session titles now localized at display time.
- 2026-09-28: Removed Home Screen widget + App Group (owner decision). Added Language row (opens iOS per-app language). Fixed Favorite toggle (asset lookups now refresh on library change; Library favorite toggles).
- 2026-09-28: Fixed full-screen preview layout (zoom constraints), blurry swipe card (thumbnail reloads with real size), redesigned swipe card (blurred backdrop + overlay info), custom preview action bar (share/limit sheets work over full-screen covers).
- 2026-09-28: App Store listing (13 locales) in appstore/LISTING.md + 65 screenshots (appstore/screenshots) via tools/capture_screens.sh + tools/make_store_screenshots.py.
- 2026-09-28: Screenshots redone after reviewing top photo-cleaner listings (Swipewipe, Cleanup, Clever Cleaner, Slidebox, Picnic): short keyword headlines, flat brand colors, big phone, sticker callouts, real photos (Unsplash via picsum.photos, in a dedicated "Shotsy Store" simulator). Slides: swipe, similar, clean, library, review. DEBUG simulator builds fall back to a color-layout vector when Vision has no inference context, so the Similar screen shows real groups; `-screenshotRoute similar` opens it.
