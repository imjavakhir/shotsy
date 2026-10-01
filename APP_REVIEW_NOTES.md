# App Review notes — Shotsy

**What the app does.** Shotsy helps people organize their photo library: sort photos with swipes, review
similar photos and screenshots, compress large videos into new copies, and keep albums tidy. All analysis runs on
the device. There is no account and no server.

**Photo library permission.** Shotsy asks for photo access only after the user taps "Continue" in
onboarding. It works with full or limited access (with a "Manage" control for limited access). Settings, restore
purchases, and legal links are available without photo access. Usage strings:
- NSPhotoLibraryUsageDescription: sorting, grouping, and searching photos on this iPhone; the library changes only
  when the user chooses an action.
- NSPhotoLibraryAddUsageDescription: saving compressed video copies the user asks for.

**Deletion flow.** Swiping left only adds a photo to Shotsy's own review queue; nothing is deleted then. To
delete, the user opens "Review deletions", can deselect items, and taps "Delete N items". Shotsy re-validates the
selection and calls PhotoKit, which shows the standard iOS confirmation. Deleted items go to Photos' Recently
Deleted album (recoverable for about 30 days). Shotsy doesn't claim instant storage recovery. Compression always
saves a new copy; the original is never replaced, and removing it goes through the same review and confirmation.

**Purchases.** One product family, "Shotsy Pro", sold as:
- Weekly auto-renewable subscription (1 week), USD 1.99 base price.
- Lifetime non-consumable, USD 19.99 base price.

Purchases are processed with RevenueCat.

Both unlock the same features. No free trial. Prices shown are the App Store's localized prices. The paywall has Restore Purchases,
Terms of Use (Apple's standard EULA unless a custom one is configured), and a Privacy Policy link, plus a visible
close button. Buying Lifetime doesn't cancel an existing weekly subscription; the app says so and offers
Manage Subscription.

**Free experience.** Browsing, albums, favorites, On This Day, 30 review decisions per day, manual screenshot
labels, one Smart Collection, and reminders are free.

**How to test.**
1. Launch → Continue → Continue → Continue → allow access.
2. Clean tab → Start sorting → swipe right (keep) and left (mark) → close → Review deletions → Delete N items →
   confirm the system alert.
3. Settings (gear) → Shotsy Pro → Restore Purchases / paywall.

**Privacy.** No tracking, no analytics SDKs, no ads. The only data that leaves the device is purchase history, which RevenueCat uses to confirm Shotsy Pro (not linked to identity). Recognized text never leaves the
device and is excluded from backups. Shotsy doesn't detect, recognize, or store faces.
