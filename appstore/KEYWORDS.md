# Keyword research — 2026-09-28

Method: App Store autocomplete (MZSearchHints) per storefront = what people type; iTunes Search API top-10
median rating count = how crowded a term is (US only; other storefronts were rate-limited). Raw data is not kept.

US findings (median ratings of top 10; lower = easier):
- Head terms: photo cleaner (16.5k), swipe delete photos (11k), camera roll cleaner (14k), sort photos (9.7k)
- Easy wins: screenshot organizer (24), similar photos (12), album organizer (258), declutter camera roll (513),
  duplicate photos remover (1.7k)
- Too crowded for launch: storage cleaner, clean up photos, free up storage (95k–114k)

Per-locale head terms used in name/subtitle (from autocomplete):
- ru: очистка фото, удалить фото свайпом, дубликаты фото, очистка памяти
- es-MX: limpiar fotos, borrar fotos, fotos duplicadas, liberar espacio
- pt-BR: limpar fotos, apagar fotos, fotos duplicadas, liberar espaço
- fr-FR: nettoyer photos, supprimer photos & doublons, libérer espace, stockage
- de-DE: fotos aussortieren, fotos löschen, speicher freigeben, fotos aufräumen
- it: pulizia foto, eliminare foto, foto duplicate, liberare spazio
- ja: 写真整理, 写真削除スワイプ, 重複写真削除, 空き容量, スクショ整理
- ko: 사진정리, 중복사진 삭제, 저장공간 정리, 갤러리 정리
- zh-Hans: 相册清理, 照片整理, 重复照片清理, 相册管家, 相册瘦身
- zh-Hant: 照片整理, 相簿清理, 重複照片清理, 相簿管家
- id: pembersih foto, hapus foto, foto duplikat, memori penuh
- vi: dọn dẹp ảnh, xoá ảnh trùng lặp, giải phóng dung lượng

Rules followed: no word repeated across name/subtitle/keywords (Apple combines them), no competitor names,
commas without spaces. Values live in appstore/metadata/<locale>.json; push with tools/asc_listing.py.
Re-check rankings a few weeks after launch and swap keywords that don't rank.
