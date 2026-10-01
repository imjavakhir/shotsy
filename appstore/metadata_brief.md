# Shotsy App Store metadata — localization brief

Source: /Users/javoxir/Documents/NEW CHAPTER/shotsy/appstore/metadata/en-US.json (read it first).
App: Shotsy — iPhone photo organizer/cleaner (swipe to keep or delete, similar/duplicate/blurry finder, screenshot inbox with text search, video compression, albums, smart collections, On This Day). Everything runs on device. Brand: friendly mascot, short and warm tone.

For each locale you're given, write /Users/javoxir/Documents/NEW CHAPTER/shotsy/appstore/metadata/<locale>.json with the SAME structure as en-US.json:
- name (≤30 chars): keep "Shotsy" + a localized, searchable descriptor, e.g. "Shotsy - <photo cleaner/organizer phrase>". Use the phrase people in that market actually search.
- subtitle (≤30 chars): benefit-led, natural, no words repeated from name.
- keywords (≤100 chars total, comma-separated, NO spaces after commas): do real ASO thinking for that market — high-intent local search terms (photo cleaner, storage, duplicates, similar photos, screenshots, delete photos, free up space, gallery, compress video…). Do NOT repeat words already in name/subtitle, no brand names of other apps, no "app", no plurals of words already present. For CJK use natural short terms.
- promotional_text (≤170 chars).
- description (≤4000 chars): natural localized marketing copy, same sections and facts as English. Keep facts exact: nothing deleted until the user confirms; Recently Deleted ~30 days; on-device analysis; Weekly $1.99/week auto-renews until canceled; Lifetime $19.99 one-time; prices may vary by country; renewal/cancel terms (24 hours); Terms of Use URL unchanged. Use Apple's official local terms (Photos, Recently Deleted, Apple Account, iCloud, Live Photo). Don't invent features, awards, ratings or discounts.
- screenshots: same 5 ids; title ≤ 32 chars ideally (it's a big headline on the image; shorter is better, CJK ≤ 14 chars), caption ≤ 40 chars. Punchy, natural, not literal.

Validate with python3 before finishing: JSON loads, all fields present, every length limit respected (count characters with len()). Fix and re-validate if anything fails.
Reply only with the files written and their name/subtitle/keywords lengths.
