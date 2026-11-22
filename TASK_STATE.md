# Project State

## Current architecture
macOS/iOS Server -> SPPW/1 (proprietary UDP, 40-byte header, no checksum (`payloadChecksum` always 0), Bonjour `_pyrowave._udp`) -> macOS/iOS Receiver.
Bitstream: vendored upstream PyroWave encoder (`Vendor/pyrowave-metal`), unchanged.

### Native SPPW/1 Transport & Media Pipeline
- **ScreenCaptureKit & ReplayKit capture**: macOS `ScreenCaptureEngine` (`SCStream` `.screen` + `.audio` @ 48 kHz stereo) with actor-reentrancy protection and zero-copy `IOSurface`-backed `CVPixelBuffer` transfer to `UpstreamMetalEncoder`; iOS `IOSScreenOutput` / `RPScreenRecorder`.
- **Asymmetric LL/HF Reed-Solomon ECC (FEC)**: Systematic Cauchy Reed-Solomon over $\text{GF}(2^8)$ (`SPPWReedSolomonGF256`, wire message `kind = 8` `.fecParity` with 8-byte `SPPWFECBlockHeader`). `SPPWPyrowaveSubbandInspector` locates the exact byte boundary of the coarse LL subband (`level == 4, band == 0` across Y/Cb/Cr) so LL fragments are tagged (`SPPWFragmentFlags.llCritical`) and receive $2\times$ parity protection (minimum 25%, $\ge 2$ parity shards) while HF detail fragments are protected in blocks of up to 48 shards.
- **Low-latency LL-drop & Partial-HF GPU decode**: `SPPWFrameAssembler` immediately drops any older incomplete frame missing unrecoverable LL packets (`llDroppedFrames`) instead of stalling on a dead frame. When LL is 100% intact and only trailing HF detail packets are lost, it salvages the valid block-aligned prefix (`isPartialHF = true`) and `PyrowaveDecoderSession.decode(_:allowPartialFrame:)` reconstructs the frame on Metal with zeroed missing HF coefficients.
- **Packet pacing, Socket buffers (`SO_SNDBUF`/`SO_RCVBUF`) & Wi-Fi jitter buffer**: POSIX dual-stack UDP sockets (`SPPWUDPServerSocket`, `SPPWUDPClientSocket`) with explicit `SO_SNDBUF`/`SO_RCVBUF` (4 MB on macOS, 2 MB on iOS with progressive fallback) and DSCP CS4 (`0x80`, WMM `AC_VI`), sub-millisecond `mach_wait_until` micro-burst pacing (`SPPWMediaPacer` with newer-frame preemption), and RFC 3550 EWMA adaptive Wi-Fi buffer (`SPPWAdaptiveWiFiBuffer`).
- **Closed-Loop Adaptive Bitrate (ABR)**: `SPPWAdaptiveBitrateController` (`Sendable`) active when `automaticBitrate == true`. Evaluates network health every **1 second** and steps bitrate down each second while packet loss (LL drop, frame expiration, late decode drop), partial-HF fallback, high FEC recovery, or Wi-Fi jitter persist until the link stabilizes. Ramp-up requires at least **10 seconds** of continuous clean link (`minimumRampUpCooldownNanoseconds = 10s`) with exponential backoff (`20s`) after a failed probe. If probing higher bitrate re-triggers link instability, it reverts immediately to the last problem-free bitrate (`.revertToStable`), and locks the safe ceiling (`isCeilingLocked = true`) if instability persists (`failedProbeCount >= 2`), eliminating bitrate oscillation on penalized networks. Both macOS `StreamServer` and iOS `IOSStreamServer` honor the dynamic receiver `maxBitrate` budget without interrupting capture (`flags == 0`).
- **Audio & Input channels**: `SPPWAudioPacketizer` + `SPPWAudioPlayer` (`AVAudioEngine` low-latency PCM16 48 kHz stereo with automatic 3 s idle pause, wire `kind = 9` `.audioFrame`) and `SPPWInputEvent` + `SPPWMacInputInjector` (`CGEvent` mouse/scroll/keyboard/touch injection, wire `kind = 4` `.input`).

## Active tasks
- [ ] **Indagine interruzione stream lato server dopo periodo di background su iOS e macOS**:
  - Indagare perché dopo un certo periodo di background lo stream si interrompe lato server sia su iOS che su macOS (sospensione runtime del processo/thread, App Nap su macOS, lifecycle di background/ReplayKit su iOS, throttling socket UDP e keepalive).
  - Provvedere a ovviare a questo problema (gestione background execution assertions, `ProcessInfo.beginActivity` per prevenire App Nap su macOS, `UIBackgroundTaskIdentifier` / background handling su iOS, ripristino automatico dello stream o heartbeat di keepalive).
  - Se necessario, inserire una **Modalità Gioco (grafica avanzata / high performance mode)** sia su iOS che su macOS per garantire priorità di scheduling GPU/CPU, frame rate elevato e prevenzione del throttling/sospensione durante sessioni ad alte prestazioni.

Completed tasks were removed from this list; their history is in git (`git log -- TASK_STATE.md`).

## Active agents
- None registered. Add `- <Name>: <area>` here while working and remove it when the turn ends.

## Shared decisions
- Native Apple APIs; keep `SPPW/1` (NativeMode) and the PyroWave bitstream format intact (MIT).
- **TimeMachine Local Snapshots:** Every agent must execute `./scripts/snapshot.sh "<Agent Role>: <summary>"` (or `git snapshot "<summary>"`) at the end of its turn to record an immutable local recovery checkpoint before ending.
- **Versioning:** Shared `VERSION` (starting at `0.5.0`) auto-bumped by all macOS/iOS packaging scripts (`--patch` $\to$ `0.5.x` minor fixes, `--minor`/`--major-fix` $\to$ `0.x.0` major fixes, `--no-bump` to keep).
- **Adaptive Bitrate (ABR):** Ceiling calculated via `width * height * 1.4 * quality * fps` quantized to 1 Mb/s. When `automaticBitrate == true`, receivers adjust runtime target in 1s ticks without overwriting user manual `bitrateMbps` setting. Servers enforce `min(autoBudget, maxBitrateCap)` and apply `.streamConfiguration` updates seamlessly without restarting capture (`flags == 0`).
- **Punktfunk: DEFERRED** — proprietary QUIC stack (`_punktfunk._udp`), no public spec/license; revisit only with official spec/permission (no decompilation).
- **Moonlight/Sunshine: DEFERRED** — clean-room MIT only (never copy GPLv3 code), behind `StreamSessionProvider`, only if a PyroWave-capable client is verified.
- **Steam Remote Play: EXCLUDED** — closed protocol/client, SSA restricts reverse engineering.

## Blockers
- None for the native `SPPW/1` pipeline (Metal backend, ScreenCaptureKit, iOS decoder, asymmetric LL/HF Reed-Solomon FEC, LL-drop + partial-HF decode, socket buffers/pacing/Wi-Fi jitter buffer, closed-loop ABR, and audio/input channels are implemented).
- Verify byte-level compatibility of our bitstream framing with upstream PyroWave (only needed if third-party interop is ever resumed).
