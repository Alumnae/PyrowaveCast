# PyrowaveKit

PyrowaveKit is an Apple-only Swift and Metal port of PyroWave for low-latency local video transport, together with a native macOS and iOS streaming stack (`SPPW/1`).

The port is intentionally native: Swift Package Manager, Metal compute, CoreVideo pixel buffers, `AVSampleBufferDisplayLayer` rendering, VideoToolbox HEVC benchmarks, and no CPU fallback path.

## Requirements

- macOS 14 or newer (Swift 6 toolchain, Metal-capable Apple GPU)
- iOS 17 or newer for the iOS app (`PyrowaveCastiOS/PyrowaveCastiOS.xcodeproj`)
- VideoToolbox-capable Apple platform runtime for HEVC comparison benchmarks

## Architecture & Targets

### Libraries

| Target | Role |
| --- | --- |
| `PyrowaveKit` | Native Swift/Metal PyroWave codec, CoreVideo sessions, rate control, and VideoToolbox HEVC comparison benchmarks |
| `CPyrowaveMetal` | Vendored upstream PyroWave Metal implementation (`Vendor/pyrowave-metal`, MIT) |
| `SPPWCommon` | Shared `SPPW/1` transport layer: asymmetric LL/HF Cauchy Reed-Solomon GF(2^8) FEC, frame assembly (LL-drop & partial-HF salvage), adaptive bitrate controller (`SPPWAdaptiveBitrateController`), POSIX dual-stack UDP sockets, pacing, adaptive Wi-Fi jitter buffer, audio and input wire codecs |
| `PyrowaveServerKit` | `SPPW/1` streaming server, macOS `ScreenCaptureKit` capture, dynamic bitrate ceiling enforcement, and test content generators (test card, image, video) |
| `PyrowaveGUI` | Shared SwiftUI views/models, 1-second ABR loop, and `AVSampleBufferDisplayLayer` playback surface |

### Executables & Apps

| Target / Script | Output |
| --- | --- |
| `pyrowave-app` (`./scripts/build-app.sh`) | Unified macOS app (`build/PyroWave.app`) running server and receiver side by side |
| `pyrowave-server-gui` (`./scripts/build-gui.sh`) | Standalone macOS server GUI (`build/PyrowaveServer.app`) |
| `pyrowave-receiver-gui` (`./scripts/build-receiver.sh`) | Standalone macOS receiver GUI (`build/PyrowaveReceiver.app`) |
| `pyrowave-server` | Headless macOS CLI server |
| `pyrowave-swift-bench` | Codec & HEVC comparison benchmark runner |
| `./scripts/build-ios.sh` | Unified unsigned iOS `.ipa` (`build/PyroWaveiOS.ipa`, minimum iOS 17) |

### SPPW/1 Transport Highlights

See [PROTOCOL.md](PROTOCOL.md) for the full wire specification (datagram header layout, message kinds, flags, FEC/audio/input payloads) and [TASK_STATE.md](TASK_STATE.md) for current project status and roadmap.

- **Protocol & discovery:** Unicast UDP (default port `9888`), 40-byte big-endian header (checksum field reserved, always 0), Bonjour `_pyrowave._udp`.
- **Asymmetric LL/HF FEC:** Systematic Cauchy Reed-Solomon over GF(2^8) (`kind = 8`), inspecting PyroWave subband boundaries to apply heavier parity to coarse LL packets while keeping HF overhead minimal.
- **Resilient low-latency decode:** Unrecoverable LL loss drops stale frames immediately; when LL is intact and trailing HF packets are lost, Metal decodes the valid prefix with zeroed HF coefficients.
- **Socket tuning & pacing:** POSIX dual-stack UDP with `SO_SNDBUF`/`SO_RCVBUF` sizing, DSCP CS4 (`AC_VI`), `mach_wait_until` micro-burst pacing, and EWMA adaptive Wi-Fi jitter buffering.
- **Closed-loop adaptive bitrate (ABR):** Evaluates network health every 1 second when `automaticBitrate == true`, steps bitrate down each second during packet loss or jitter, holds ramp-up for $\ge 10$ seconds of clean link, and reverts/locks to the problem-free bitrate if instability persists to avoid oscillation.
- **Audio & input:** 48 kHz stereo PCM16 audio (`kind = 9`, `AVAudioEngine`) from both servers in screen capture mode (macOS ScreenCaptureKit system audio; iOS ScreenCaptureKit audio on iOS 27, ReplayKit app audio otherwise, resampled to 48 kHz) and mouse/scroll/keyboard/touch input forwarding (`kind = 4`, `CGEvent` on macOS).
- **Server audio controls:** an *Audio source* picker reads the sources from the system — none, system audio, or an input device (macOS microphones via ScreenCaptureKit, macOS 15+; iOS `AVAudioSession` inputs via `AVAudioEngine`) — plus an *Input volume* slider (0–200%, live). In video file mode the file's own audio track is streamed (tapped from `AVPlayer`, silent on the server) on the same timeline as its frames.
- **Remote control (iOS receiver → macOS server):** keyboard, mouse and clipboard over `SPPW/1`. Committed text from the system keyboard — including IME composition such as Chinese Pinyin, accents and dictation — is sent as Unicode (`.text`) and typed with `CGEventKeyboardSetUnicodeString`, so the Mac's own input source never re-interprets it; special keys, hardware keyboards and shortcuts are sent as macOS virtual key codes with modifier flags (`.key` / atomic `.keyPress`). Trackpad mode sends relative pointer motion (`.pointerDelta`) and clicks at the cursor (`.clickAtCursor`, `.buttonAtCursor`); discrete events travel in a `.sequenced` envelope sent twice and applied once. Clipboard sync (`kind = 10`, UTF-8 text and PNG up to 1 MiB / 8 MiB, chunked with retransmission) runs while the server allows remote control: Mac → iPhone automatically (`NSPasteboard` `changeCount` polling, password-manager items skipped), iPhone → Mac only on an explicit paste (`UIPasteControl`, no permission prompt). iPhone writes are `localOnly`, so Universal Clipboard and the channel never bounce items back and forth. In the iOS receiver's fullscreen view a dock offers trackpad or direct-touch mode, the system keyboard, a special keys sheet (F1–F12, Esc, Mac shortcuts, navigation), a clipboard paste button, sticky ⇧⌃⌥⌘ (tap: next key, double tap: lock) and a right-click toggle; hardware keyboards send key codes with client-side auto-repeat, and iPad mice/trackpads use `GCMouse` with pointer lock. Gestures: one finger moves, tap clicks, two fingers scroll (with momentum), two-finger tap right-clicks, press and hold to drag, three-finger tap shows or hides the controls. Settings → *Remote control* holds touch mode, pointer speed, natural scrolling and clipboard sync. When the video is rotated in the iOS receiver (rotate button), the on-screen controls turn with it and trackpad, mouse and scroll motion follow the picture as shown (the mirror flip never mirrors the controls). Both receivers magnify the video up to 2× (`SPPWViewZoom`): on iOS pinch with two fingers (the pinch's movement pans; taps map through the zoom; the *1.5×* badge resets), on macOS pinch on the trackpad, the *− 1.0× +* control or ⌘+ / ⌘− / ⌘0 (only while the keyboard is not captured, so those keys still reach the remote Mac). With remote control on, the macOS viewport follows the pointer; without it, scrolling pans. On macOS the overlays stay upright for in-app rotation, since macOS itself rotates the whole interface when a display is rotated. While a receiver shows its own pointer the server leaves the delayed Mac cursor out of the video (`cursorVisibility`): the macOS receiver with remote control on, and the iOS receiver's fullscreen view in every mode, which draws its own arrow (`SPPWLocalPointer`) and sends absolute positions (`.pointerMove`) for trackpad swipes, iPad mice and direct touch, so the arrow is exactly where the Mac clicks (it starts in the middle of the remote screen). Number fields on the iOS main screens have a bar above the keyboard with a button that hides it. In the macOS receiver the video controls (remote control, rotate, mirror, zoom, fullscreen and its *Exit*) are grouped behind a small floating button with the app logo, at 50 % opacity until hovered: drag it anywhere over the video (the position is remembered), click it for the controls, so no bar covers the remote screen's top-right corner. In fullscreen, pressing and releasing ⌃⌥ on its own also leaves fullscreen, while ⌃⌥+key shortcuts still go to the remote Mac.
- **Client-chosen resolution:** the receiver picks *Native*, *Automatic* or a short-side level (2160p, 1440p, 1080p, 720p, 480p, 360p, 320p); the server derives the exact size from its own aspect ratio and never upscales. *Automatic* steps the level down/up from the adaptive bitrate.
- **iOS screen casting in the background:** the iOS app embeds a ReplayKit Broadcast Upload Extension (`PyrowaveCastiOS/PyrowaveCastBroadcast`, bundle `com.pyrowavecast.ios.broadcast`). Started from the *Cast screen in the background* button in Screen mode (the system broadcast picker) or from Control Center → Screen Recording → PyrowaveCast, it runs the same `IOSStreamServer` (UDP, Bonjour, FEC, pacing, Metal PyroWave encoder) in its own process with ReplayKit's system-wide screen and app audio, so casting continues while PyrowaveCast is in the background, on the Home Screen or with the device locked. It listens on UDP 9888 (or the app's port when both share the `group.com.pyrowavecast.ios` App Group); the in-app server stops first to free the port. Extensions are limited to about 50 MB of memory, so lower capture levels are safer on large iPad screens.
- **Background resilience:** while streaming, servers and receivers hold a process activity assertion (no App Nap, precise timers, no idle/display sleep while capturing or watching); the macOS server automatically restarts a capture that ScreenCaptureKit stopped; on a still screen (ScreenCaptureKit and ReplayKit send no new frames) both servers resend the last encoded frame every second, so receivers never mistake a static desktop for a lost stream; a receiver resync (`streamConfiguration` with flag `0x0001`) only gets the last frame again instead of a capture restart, unless the capture is dead, the geometry changed or nothing came from it for 3 s, and the macOS server restarts a capture that stayed silent for 8 s while the user clicks, types or scrolls; receivers keep the last picture on screen during a resync or an automatic reconnect instead of clearing to black, and drop a late frame only when a newer one is already waiting (so a slow first decode at 4K+ is still shown); on iOS auto-lock is disabled while the server or receiver is active. On iOS the *Screen* source's start button (*Share the whole screen*) opens the system broadcast sheet: the Broadcast Upload Extension runs the server in its own process, so the whole screen keeps streaming on the Home Screen and in other apps, where the app itself may not encode (no background GPU). The in-app iOS server (test card, image, video file) keeps streaming in the background through a continued-processing background task (`BGContinuedProcessingTask`, iOS 26+) with background GPU access on supported devices (it needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement when you sign the app, and iOS shows its progress as a Live Activity). Without background GPU access, video pauses in the background while the session stays connected, and it resumes on return; a system screen capture that iOS stopped is restarted automatically when the app is back on screen.
- **Lip sync:** video frames and audio packets carry their capture instant on one sender clock. Receivers measure the capture-to-screen video delay (`SPPWAVSyncClock`) and a jitter buffer (`SPPWAudioJitterController`) keeps the audio queue at the depth that matches it — never below a safe minimum, corrected at most every 250 ms by 5–10 ms — so audio follows video without dropouts; video keeps its lowest-latency path.
- **Chroma 4:2:0 / 4:4:4:** Streams default to 8-bit 4:2:0 (NV12 capture and output). The macOS server can opt into full colour 4:4:4 (GUI toggle "Full color 4:4:4", CLI `--chroma444`): ScreenCaptureKit captures 10-bit `'xf44'`, the vendored encoder codes PyroWave 4:4:4, and receivers read the chroma mode from the PyroWave sequence header and decode to BGRA (BT.709) for `AVSampleBufferDisplayLayer`. No `SPPW/1` change; the iOS server (ReplayKit) stays 4:2:0. 4:4:4 costs roughly twice the samples per frame, so expect higher bitrate and GPU time.

## Build & Run

### Swift Package

```shell
swift build
```

> Note: On sandboxed macOS/Xcode environments, pass `--disable-sandbox` (as used by the packaging scripts).

### Automatic Versioning (`VERSION`)

All macOS and iOS packaging scripts share `VERSION` (via `scripts/version.sh`) and keep `PyrowaveCastiOS/PyrowaveCastiOS/Info.plist` synchronized automatically:

- **Regola di incremento Z ad ogni build**: ogni volta che viene eseguito un build, la cifra **Z** di `X.Y.Z` viene incrementata (`--patch`: `0.x.z` → `0.x.(z+1)`).
- Incrementi maggiori (`--minor` o `--major-fix`): avanzano a `0.(x+1).0`.
- Mantenimento versione (`--no-bump` o `PYROWAVE_BUMP=none`): riservato solo a verifiche o riesecuzioni senza nuova build di rilascio.

### macOS App Bundles

The packaging scripts build release binaries and embed the required `PyrowaveKit_PyrowaveKit.bundle` Metal shader resource bundle into `Contents/Resources/`:

```shell
./scripts/build-app.sh                # Unified server + receiver -> build/PyroWave.app (bumps 0.5.x)
./scripts/build-app.sh --major-fix    # Major fix release         -> bumps 0.x.0
./scripts/build-gui.sh                # Standalone server         -> build/PyrowaveServer.app
./scripts/build-receiver.sh           # Standalone receiver       -> build/PyrowaveReceiver.app
```

`build-app.sh` always signs ad hoc: the repositories are public, so builds never carry a personal signing identity. macOS may ask for the Screen Recording permission again after a rebuild.

### iOS App

```shell
./scripts/build-ios.sh                # Unsigned IPA -> build/PyroWaveiOS.ipa (bumps 0.5.x)
./scripts/build-ios.sh --no-bump      # Package iOS with the same VERSION as macOS
```

### App Icon

The icon source is `Resources/AppIcon/AppIcon.svg`. After editing it, regenerate every derived asset (iOS `AppIcon.appiconset`, the multiplatform Xcode app's `AppIcon.appiconset`, and `Resources/AppIcon/AppIcon.icns` used by the `build-*.sh` macOS bundles via `CFBundleIconFile`):

```shell
python3 Resources/AppIcon/generate.py   # needs macOS (qlmanage, iconutil) and Pillow
```

### CLI Server

```shell
swift run -c release pyrowave-server --port 9888
swift run -c release pyrowave-server --chroma444   # full colour 4:4:4 screen capture
# Test modes (no Screen Recording permission required):
swift run -c release pyrowave-server --test
swift run -c release pyrowave-server --test-image /path/to/image.png
swift run -c release pyrowave-server --test-video /path/to/video.mp4
```

## Test

```shell
swift test
swift test -c release
```

Coverage includes packet decoding, wavelet padding/filtering, 4:2:0 and 4:4:4 round trips, rate control, Metal parity checks (`PyrowaveKitTests`), and the `SPPW/1` transport pipeline—Cauchy Reed-Solomon FEC, subband LL boundary inspection, partial-HF assembly, pacing, audio, and input (`SPPWPipelineTests`), plus the remote control wire events, keyboard translation, sticky modifiers and clipboard channel (`SPPWRemoteControlTests`).

## Benchmarks

Pyrowave is compared against a Mirage-style realtime HEVC path built on VideoToolbox.

```shell
swift run -c release pyrowave-swift-bench --frames 60 --preset 6k --output-dir .pyrowave-results
```

Reports are written to `.pyrowave-results/`, which is git ignored.

Rules:
- Pyrowave has no byte cap.
- HEVC quality is capped at `0.8`.
- HEVC uses realtime VideoToolbox settings: no frame reordering, low delay, Mirage-style QP bounds, `AverageBitRate`, and `DataRateLimits`.
- Timings exclude loading, pixel-buffer setup, metric conversions, artifact writes, report serialization, and PSNR calculation.
- Every report also includes `productionPath` timings for serial CoreVideo encode, actual-payload export, contiguous bitstream decode, and pooled output-buffer acquisition. `packetSlotCapacityBytes` is reported separately from bytes actually exported.

Latest 60-frame results from July 4, 2026:

```shell
swift run -c release pyrowave-swift-bench --preset 1080p --frames 60 --output-dir .pyrowave-results/2026-07-04-second-pass-final-hevc-1080p-60
swift run -c release pyrowave-swift-bench --preset 4k --frames 60 --output-dir .pyrowave-results/2026-07-04-second-pass-final-hevc-4k-60
swift run -c release pyrowave-swift-bench --preset 6k --frames 60 --output-dir .pyrowave-results/2026-07-04-second-pass-final-hevc-6k-60
```

### Performance

| Size | Py encode | Py decode | HEVC encode | HEVC decode | Py encode speedup | Py decode speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1080p | 1.067 ms | 0.937 ms | 5.865 ms | 0.398 ms | 5.497x | 0.425x |
| 4K | 5.017 ms | 1.533 ms | 19.602 ms | 1.388 ms | 3.907x | 0.905x |
| 6K | 8.211 ms | 3.019 ms | 44.543 ms | 4.107 ms | 5.425x | 1.360x |

### Size and Quality

| Size | Py bytes/frame | HEVC bytes/frame | Byte ratio | PSNR delta |
| --- | ---: | ---: | ---: | ---: |
| 1080p | 115,066.3 | 29,302.0 | 3.927x | +1.449 dB |
| 4K | 450,154.7 | 111,520.8 | 4.037x | +0.237 dB |
| 6K | 1,144,178.2 | 164,876.0 | 6.940x | +6.263 dB |

Speedups above `1.0x` mean Pyrowave is faster than HEVC. Current results: faster encode at every size, faster decode at 6K, slower decode at 1080p and 4K.

## License

MIT License — see [LICENSE](LICENSE). Includes vendored upstream PyroWave Metal sources (`Vendor/pyrowave-metal`, MIT, Hans-Kristian Arntzen).

## Credits

PyrowaveCast builds on earlier open-source work, whose full commit history is not carried over into this repository:

- [PyroWave](https://github.com/Themaister/pyrowave) by Hans-Kristian Arntzen — the original wavelet codec and bitstream (MIT).
- [PyrowaveKit](https://github.com/EthanLipnik/PyrowaveKit) by Ethan Lipnik — the Swift/Metal port this project started from (MIT).
