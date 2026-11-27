# Kimz Clean Recorder

A macOS screen recorder with AI noise cancellation and voice enhancement built in.
Pick a screen, pick a mic, press Record, and you get a small, sharp `.mp4` with clean audio.

## Features

- **Pick any connected screen.** Live thumbnails, native Retina resolution, 30 or 60 fps.
- **Mic picker.** Lists every connected mic. USB mics are picked up when you plug them in, and you can **switch mics while recording**. If the active mic is unplugged, it falls back to the system default.
- **Mic volume slider** from 0–200%, also adjustable while recording. Double-click the % to reset it to 100%.
- **Noise cancel** with DeepFilterNet3 (on-device AI, model embedded in the app).
- **Enhance voice:** EQ, compressor and de-esser, shaped by a **voice style** (Natural, Warm, Soft, Bright, Broadcast). **Soft** tames sharp "s" sounds from bright or close mics like headsets.
- **Depth slider:** bass boost, deeper voice and stronger bass (low-shelf boost below ~160 Hz), adjustable while recording.
- **Air restore** (Auto for headset mics): rebuilds the 8–11 kHz crispness that call-quality mics like the Jabra Evolve2 65 don't record. Any mic format is converted to 48 kHz automatically.
- **Power slider:** an "amplified", radio-style voice: fast compression plus saturation, so it sounds bigger at the same loudness.
- **Extra voice tools** (in Settings): pop reducer, AI silence & keyboard cleanup (voice gate driven by the model's speech detection), light room echo reduction, warmth.
- **Loudness normalization** after recording, to −14 LUFS (YouTube) or −16 LUFS (podcast). The video is copied untouched.
- **Hear yourself:** live headphone monitoring of the processed voice.
- **Limiter** always on, so the audio never clips.
- **Record / Pause / Stop.** Pausing leaves no gap or frozen frame in the file.
- **Small files:** HEVC hardware encoding by quality target rather than fixed bitrate. Static screens cost almost nothing.
- **Light / Dark / System theme.**
- **Menu bar controls and timer.** The window hides while recording, and the app's own windows never appear in the video.
- **Closing the window quits the app** completely (nothing keeps running). If you quit during a recording, it stops and saves first.
- **Low energy when idle:** the mic and AI processing run only while the window or menu bar panel is open, while recording, or while monitoring. With the window closed the app idles in the menu bar (no orange mic dot).
- **Optional clean `.wav`** saved next to the video, for editing.

| Shortcut | Action |
|---|---|
| ⌃⌘R | Record / stop |
| ⌃⌘P | Pause / resume |

Files go to `~/Movies/Kimz Clean Recorder/`. You can change the folder in Settings.

## Install

Download **Kimz-Clean-Recorder.dmg** from the latest GitHub Actions run (or the file you were sent), open it, and drag **Kimz Clean Recorder** into **Applications**.

The app isn't notarized by Apple, so the first launch is blocked. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

## Build it yourself (optional)

You need macOS 14 or later, Xcode 15 or later, and [Homebrew](https://brew.sh).

```bash
# 1. Tools
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # Rust
brew install xcodegen

# 2. Build the noise-cancel library (first time takes ~5–10 min)
./Scripts/build-dfn.sh            # Apple Silicon; add --universal to also support Intel Macs

# 3. Generate and open the Xcode project
xcodegen
open CleanRecorder.xcodeproj
```

In Xcode, open **Target → Signing & Capabilities** and choose your **Team**. Without a team the app is signed ad-hoc, and macOS will ask for screen recording permission again after every build. Then press **Run**.

On first launch:
1. Allow **Microphone** access.
2. Allow **Screen & System Audio Recording** in System Settings, then **quit and reopen** the app. macOS requires the restart.

## How it works

```
Mic (AVCaptureSession, 48 kHz mono)
  → high-pass 80 Hz
  → DeepFilterNet3 (Rust)        noise removal, 30 ms delay (compensated)
  → mic gain (0–200 %)
  → voice gate (AI speech detection)
  → pop reducer → room echo reduction → depth (bass)
  → EQ → compressor → power → air restore → de-esser   "Enhance voice" (voice style)
  → warmth → limiter (-1 dBFS)    → headphones (optional)
  ┐
  ├→ AVAssetWriter → .mp4 (HEVC video + AAC 192 kbps) [+ .wav]
  ┘
Screen (ScreenCaptureKit, selected display, native pixels)
```

Video and audio share the host clock, so they stay in sync through pauses and mic switches. Gaps are filled with silence and clock drift is corrected.

```
App/
  CleanRecorderApp.swift      window, menu bar, settings scenes
  Recorder.swift              state + recording lifecycle (single source of truth)
  Capture/ScreenCapture.swift ScreenCaptureKit stream + display list
  Capture/MicCapture.swift    mic list, hot-plug, live switching
  Audio/AudioProcessor.swift  the audio chain above
  Audio/DSP.swift             biquad, compressor, de-esser, limiter
  Recording/MovieWriter.swift HEVC/AAC writer with pause support + loudness meter
  Recording/LoudnessNormalizer.swift  post-recording loudness pass
  Views/                      control panel, menu bar panel, settings
dfn/                          Rust wrapper around DeepFilterNet (C API in include/dfn.h)
```

## Tuning

- **File size vs. sharpness:** Settings → Quality. Balanced, High (default) or Maximum.
- **Voice sound:** the values at the top of each struct in `Audio/DSP.swift`, such as EQ gains, compressor threshold and ratio, and the de-esser threshold.
