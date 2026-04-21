# Cutout

**Animated stickers from any video — on-device, offline, no account.**

Pick a video (your cat yawning, your kid dancing, your friend reacting),
tap **Cut Out Subject**, and get back a transparent animated clip you
can drop into:

- **iMessage** — save as GIF to Photos, long-press it in Messages to
  add as an animated sticker
- **LINE / WhatsApp / Discord / Telegram** — share the transparent
  HEVC or animated GIF directly
- **Instagram / TikTok Reels** — use the transparent HEVC as an
  overlay layer in CapCut / Reels editor
- **LINE Creators Market** — dedicated pack builder in the Pack tab
  outputs a submission-ready ZIP

## How it works

1. Vision `VNGeneratePersonSegmentationRequest(.accurate)` for the
   first-frame subject mask (humans).
2. Falls back to [CoreMLZoo](https://github.com/john-rocky/CoreMLZoo)
   `BackgroundRemovalRequest` (RMBG-1.4) when no person is detected —
   pets, products, plushies, whatever.
3. `VideoMattingSession` (CoreMLZoo → MatAnyone) propagates the
   first-frame mask across every frame, per-frame ring buffer so the
   mask stays temporally stable.
4. Output formats:
   - **Transparent HEVC `.mov`** (`AVVideoCodecType.hevcWithAlpha`) — for
     Instagram / Reels / compositor apps
   - **Animated GIF** — for chat apps (LINE, Discord, WhatsApp, iMessage)
   - **LINE-compliant APNG** + `main.png` + `tab.png` — for LINE
     Creators Market submission (Pack tab)

## Two modes

### Cutout tab — one sticker at a time
The default flow for 99% of uses. Pick video → cut out → share. Saves
as GIF to Photos so iMessage's **Make Sticker** long-press turns it
into a reusable animated sticker.

### Pack tab — LINE Creators Market submission
Build a full **8 / 16 / 24-sticker submission bundle**:
1. Pick pack size (matching LINE's allowed counts)
2. Fill each slot with a video (tap "+")
3. Tap ⭐ on any ready slot to use it as the main/tab icon source
4. **Process All Queued** — sparse-sampled MatAnyone (16 inferences per
   slot instead of every source frame) + APNG encoding
5. **Export LINE ZIP** — emits `line_pack_N.zip` containing:
   - `01.png` … `NN.png` (animated APNGs, LINE-spec compliant)
   - `main.png` (240×240 static)
   - `tab.png` (96×74 static)

Typical batch time on iPhone 13: **~15 s per slot**. A 24-sticker pack
finishes in under 6 minutes.

## Requirements

- iOS 17+
- iPhone 13 or newer recommended — older devices run MatAnyone slower
  than real-time.

## First run

The app downloads MatAnyone (~111 MB) + RMBG (~42 MB) from HuggingFace
via CoreMLZoo on first use. Downloads resume across app launches.
After first run: fully offline.

## Known limits

- MatAnyone canvas is **768×432 landscape**. Portrait clips are rotated
  to fit (slight crop on extreme aspects).
- Very fast motion and half-transparent subjects (glass, smoke) produce
  fringing — MatAnyone model limit.
- Per-frame inference ~300-500 ms on iPhone 13, ~150 ms on 15 Pro.

## Dogfooding

Cutout is the reference consumer app for
[CoreMLZoo](https://github.com/john-rocky/CoreMLZoo). Bugs in
`VideoMattingSession`, `BackgroundRemovalRequest`, or the download
manager surface here first.

## Pre-App-Store checklist

Things you (the dev) still need to provide before submission:

- [ ] **App Icon** — drop a 1024×1024 PNG into
      `Cutout/Assets.xcassets/AppIcon.appiconset/`
- [ ] **Launch screen** — either storyboard or leave the generated
      default (`INFOPLIST_KEY_UILaunchScreen_Generation = YES` is
      already set in `project.pbxproj`)
- [ ] **App Store screenshots** — 6.7" + 6.1" + iPad (if you want
      iPad) per Apple's current spec
- [ ] **Privacy manifest** — `PrivacyInfo.xcprivacy` is optional for
      this app (no tracking, no third-party analytics), but Apple
      recommends declaring the API categories you use. Add one if the
      submission flags require it.
- [ ] **TestFlight internal round** — MatAnyone + RMBG download on
      first run is the main thing to verify on cellular/offline

Everything else (bundle id, entitlements, capabilities) is already
wired in the project.

## License

MIT (app code). Model weights follow their own licenses — see the
CoreMLZoo manifest for MatAnyone (NTU S-Lab 1.0) and RMBG (Creative
Commons).
