# PyrowaveKit

PyrowaveKit is an Apple-only Swift and Metal port of PyroWave for low-latency local video transport, together with a native macOS and iOS streaming stack (`SPPW/1`).

The port is intentionally native: Swift Package Manager, Metal compute, CoreVideo pixel buffers, `AVSampleBufferDisplayLayer` rendering, VideoToolbox HEVC benchmarks, and no CPU fallback path.

## Requirements

- macOS 14 or newer (Swift 6 toolchain, Metal-capable Apple GPU)
- iOS 17 or newer for the iOS app (`iOSServer/iPyroServer.xcodeproj`)
- visionOS 1.1+ package target support
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
- **Audio & input:** 48 kHz stereo PCM16 audio (`kind = 9`, `AVAudioEngine`) and mouse/scroll/keyboard/touch input forwarding (`kind = 4`, `CGEvent` on macOS).

## Build & Run

### Swift Package

```shell
swift build
```

> Note: On sandboxed macOS/Xcode environments, pass `--disable-sandbox` (as used by the packaging scripts).

### Automatic Versioning (`VERSION`)

All macOS and iOS packaging scripts share `VERSION` (via `scripts/version.sh`) and keep `iOSServer/iPyroServer/Info.plist` synchronized automatically:

- Default (`--patch`): increments minor/patch builds (`0.5.x` → `0.5.(x+1)`)
- Major fixes (`--minor` or `--major-fix`): increments to `0.(x+1).0`
- Keep current version (`--no-bump` or `PYROWAVE_BUMP=none`): useful when packaging macOS and iOS for the same release

### macOS App Bundles

The packaging scripts build release binaries and embed the required `PyrowaveKit_PyrowaveKit.bundle` Metal shader resource bundle into `Contents/Resources/`:

```shell
./scripts/build-app.sh                # Unified server + receiver -> build/PyroWave.app (bumps 0.5.x)
./scripts/build-app.sh --major-fix    # Major fix release         -> bumps 0.x.0
./scripts/build-gui.sh                # Standalone server         -> build/PyrowaveServer.app
./scripts/build-receiver.sh           # Standalone receiver       -> build/PyrowaveReceiver.app
```

Set `PYROWAVE_CODESIGN_IDENTITY` before running `./scripts/build-app.sh` to keep macOS Screen Recording permissions stable across rebuilds.

### iOS App

```shell
./scripts/build-ios.sh                # Unsigned IPA -> build/PyroWaveiOS.ipa (bumps 0.5.x)
./scripts/build-ios.sh --no-bump      # Package iOS with the same VERSION as macOS
```

### CLI Server

```shell
swift run -c release pyrowave-server --port 9888
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

Coverage includes packet decoding, wavelet padding/filtering, 4:2:0 and 4:4:4 round trips, rate control, Metal parity checks (`PyrowaveKitTests`), and the `SPPW/1` transport pipeline—Cauchy Reed-Solomon FEC, subband LL boundary inspection, partial-HF assembly, pacing, audio, and input (`SPPWPipelineTests`).

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
