# Cutout

Turn any short video into a transparent sticker — fully on-device.

Pick a clip, tap **Cut Out Subject**, get back a transparent HEVC / GIF /
**LINE-compliant APNG** of just the subject. Save to Photos, share to LINE
Creators Market / iMessage / TikTok / Instagram. No account, no upload,
no subscription.

## LINE sticker support

Two modes:

### Cutout tab — single sticker
`Export as LINE Sticker` on a matted clip produces three files:
- **sticker.png** — animated APNG matching LINE's animation sticker spec
  (≤ 320×270 canvas with the longer side ≥ 270 px, 15 frames, 1/2/3/4 s
  playback, ≤ 1 MB, transparent RGB).
- **main.png** — 240×240 static preview.
- **tab.png** — 96×74 static tab icon.

### Pack tab — full submission bundle
1. Pick pack size (**8 / 16 / 24**, matching LINE's allowed counts)
2. Fill each slot with a video (tap "+")
3. Tap ⭐ on any ready slot to use it as the main/tab icon source
4. **Process All Queued** — sparse-sampled MatAnyone (16 inferences / slot
   instead of every source frame) + APNG encoding
5. **Export LINE ZIP** — emits a single `line_pack_N.zip` containing:
   - `01.png` … `NN.png` (animated stickers)
   - `main.png` (240×240)
   - `tab.png` (96×74)

Typical batch time on iPhone 13: **~15 s per slot**, so a full 24-sticker
pack finishes in under 6 minutes. Earlier versions processed every source
frame; `StickerPipeline` samples only the frames that end up in the
APNG (15 outputs + 1 pre-warm), dropping the previous 24-minute estimate
by ~8×.

The ZIP is verified to stay under LINE's 60 MB limit and is shareable
directly to AirDrop / Mail / iCloud for upload to
[LINE Creators Market](https://creator.line.me/).

## How it works

1. Vision `VNGeneratePersonSegmentationRequest(.accurate)` for the
   first-frame subject mask (humans).
2. Falls back to [CoreMLZoo](https://github.com/john-rocky/CoreMLZoo)
   `BackgroundRemovalRequest` (RMBG-1.4) when no person is detected —
   pets, products, plushies, whatever.
3. `VideoMattingSession` (CoreMLZoo → MatAnyone) propagates the
   first-frame mask across every remaining frame, with a per-frame ring
   buffer so the model stays temporally stable.
4. Each frame is composited into a transparent-HEVC `.mov` via
   `AVAssetWriter` (`AVVideoCodecType.hevcWithAlpha`), then optionally
   downscaled to an animated GIF for chat apps.
5. Portrait sources are rotated to landscape before inference (MatAnyone
   is locked to 768×432) and rotated back on export.

## Requirements

- iOS 17+
- iPhone 13 or newer recommended — older devices run MatAnyone slower than
  real-time.

## First run

Tap **Cut Out Subject** for the first time and the app downloads the
MatAnyone mlpackages (~111 MB) and RMBG (~42 MB) from HuggingFace via
CoreMLZoo. The download is explicit so App Review can see it, and resumes
automatically across app launches. Subsequent runs are offline-only.

## Known limits

- MatAnyone canvas is **768×432 landscape**. Portrait clips are rotated
  to fit, so extreme aspect ratios (≥16:9 height) get a minor crop.
- Per-frame inference is ~300-500 ms on iPhone 13 / ~150 ms on iPhone 15
  Pro. A 5-second 30 fps clip takes about 1 minute on an iPhone 13,
  30 seconds on a 15 Pro.
- Very fast motion (e.g. spinning objects) and half-transparent subjects
  (glass, smoke) can produce fringing — this is a MatAnyone limit.

## Dogfooding

Cutout is the reference consumer app for
[CoreMLZoo](https://github.com/john-rocky/CoreMLZoo). Bugs in the SDK's
`VideoMattingSession`, `BackgroundRemovalRequest`, or download manager
surface here first.

## License

MIT (app). Model weights follow their own licenses — see the CoreMLZoo
manifest for MatAnyone (NTU S-Lab 1.0) and RMBG (Creative Commons).
