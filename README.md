# Cutout

Turn any short video into a transparent sticker — fully on-device.

Pick a clip, tap **Cut Out Subject**, get back a transparent HEVC / GIF of
just the subject. Save to Photos, share to LINE / iMessage / TikTok /
Instagram. No account, no upload, no subscription.

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
