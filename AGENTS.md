# Agent Instructions

## Project Direction

PyrowaveKit is an Apple-only Swift and Metal port of PyroWave together with a native macOS and iOS low-latency streaming stack (`SPPW/1`). Treat the project as a native Apple codec and transport suite, not as a compatibility layer for the old Vulkan/C++ implementation.

- Keep the core package Swift Package Manager based (`Package.swift`); the unified iOS app builds via `PyrowaveCastiOS/PyrowaveCastiOS.xcodeproj`.
- Keep codec entry points centered on Metal textures and CoreVideo pixel buffers, and video display on `AVSampleBufferDisplayLayer` (no `CIContext` conversion path).
- Do not add CPU fallback paths for wavelet encode/decode.
- Do not change the PyroWave bitstream format (`Vendor/pyrowave-metal`, upstream MIT) or break `SPPW/1` NativeMode.
- Do not preserve legacy or third-party protocol compatibility unless the user explicitly asks for it.
- Convert any old Vulkan-style GPU work, including sparse block application, into Metal compute kernels or Metal-backed Swift orchestration.

## Repository Map & Shared State

- `Sources/PyrowaveKit`: Swift/Metal PyroWave codec, CoreVideo sessions, rate control, VideoToolbox HEVC benchmark.
- `Vendor/pyrowave-metal` (`CPyrowaveMetal`): Vendored upstream PyroWave Metal implementation (MIT).
- `Sources/SPPWCommon`: Shared `SPPW/1` wire/transport helpers — asymmetric LL/HF Cauchy Reed-Solomon GF(2^8) FEC, frame assembler (LL-drop + partial-HF salvage), adaptive bitrate controller (`SPPWAdaptiveBitrateController`), POSIX UDP sockets, pacing, adaptive Wi-Fi buffer, audio & input codecs.
- `Sources/PyrowaveServerKit`: `SPPW/1` streaming server, macOS `ScreenCaptureKit` capture, test sources.
- `Sources/PyrowaveGUI`: Shared SwiftUI views/models (`pyrowave-app`, `pyrowave-server-gui`, `pyrowave-receiver-gui`).
- `PyrowaveCastiOS/PyrowaveCastiOS.xcodeproj`: Unified iOS server + receiver app (compiles `PyrowaveKit`, `PyrowaveServerKit`, `SPPWCommon`, and vendored Metal sources directly).
- `VERSION` & `scripts/version.sh`: Single source of truth for macOS & iOS app versions (`0.5.x` minor/patch bumps, `0.x.0` major-fix bumps).
- `PROTOCOL.md`: `SPPW/1` wire specification — keep it in sync whenever changing headers, message kinds, flags, or payloads.
- `TASK_STATE.md`: Shared multi-agent task list and decisions — always re-read before editing so concurrent agents do not overwrite each other's updates.
- `scripts/snapshot.sh`: TimeMachine-style local snapshot helper (`git snapshot "<Turn summary>"`).

## Multi-Agent TimeMachine Snapshots (MANDATORY AT END OF TURN)

To ensure the repository acts like **macOS Time Machine** and allow instant rollback or cherry-picking of functions if an agent or refactor breaks anything:

- **Every agent MUST create a TimeMachine snapshot before ending its turn:**
  ```shell
  ./scripts/snapshot.sh "<Agent Role/Name>: <brief summary of turn work>"
  # or equivalently:
  git snapshot "<Agent Role/Name>: <brief summary of turn work>"
  ```
- **How to jump back to any previous state:**
  - View snapshots: `git log --oneline --grep="TimeMachine"`
  - Inspect code at a snapshot: `git checkout <hash>`
  - Return to latest master: `git checkout master`
  - Restore a single function/file from past: `git restore --source=<hash> <file>`

## Platform, Concurrency & Licensing Constraints

- **Deployment targets:** macOS 14+, **iOS 17.0 minimum** (`Package.swift` `.iOS(.v17)`, Xcode `IPHONEOS_DEPLOYMENT_TARGET = 17.0`). visionOS is not supported.
- **iOS compatibility:** In files compiled for iOS (`PyrowaveKit`, `SPPWCommon`, `PyrowaveServerKit`, `PyrowaveCastiOS`), guard macOS-only VideoToolbox / ScreenCaptureKit APIs and anything newer than iOS 17. Prefer the existing `PyrowaveClock` helper for timing.
- **Swift 6 strict concurrency:** Keep UDP receive, FEC reconstruction, and frame assembly off `@MainActor`; only completed frames/UI stats hop to `@MainActor`.
- **Licensing (MIT):** Never copy GPLv3 code (e.g., Sunshine or `moonlight-common-c`). Never decompile closed-source software (e.g., Punktfunk, Steam Remote Play).

## Performance Priorities

Performance work should focus on real app behavior:

- Avoid benchmark-only shortcuts that a normal app could not use.
- Do not include input loading, artifact writing, report serialization, PSNR calculation, or metric pixel conversion in encode/decode timings.
- Keep Pyrowave uncapped by byte size or quality ceiling unless a specific test requests a limit.
- Compare HEVC using the strongest realtime VideoToolbox path available in this repo, aligned with the Mirage-style benchmark behavior.
- HEVC quality should remain capped at `0.8`.
- HEVC should use realtime settings such as no frame reordering, low delay, QP bounds, `AverageBitRate`, and `DataRateLimits` where supported.

## Build, Packaging & Benchmarks

- Release app packaging scripts (all embed `PyrowaveKit_PyrowaveKit.bundle`, pass `--disable-sandbox` where needed, and auto-bump `VERSION` + sync `PyrowaveCastiOS/PyrowaveCastiOS/Info.plist`):
  - `./scripts/build-app.sh` → `build/PyroWave.app` (unified macOS)
  - `./scripts/build-gui.sh` → `build/PyrowaveServer.app`
  - `./scripts/build-receiver.sh` → `build/PyrowaveReceiver.app`
  - `./scripts/build-ios.sh` → `build/PyroWaveiOS.ipa` (unsigned, iOS 17+)
- **Code signing:** never sign builds with a personal Apple Development / Developer ID identity — the repositories are public. `build-app.sh` signs ad hoc only, the iOS `.ipa` stays unsigned, and no `DEVELOPMENT_TEAM` is committed to the Xcode projects.
- **Regola Obbligatoria sul Versionamento di Build (Incremento Z):**
  - **Ogni volta che si esegue una build, la cifra Z di `X.Y.Z` (patch version) DEVE essere incrementata:**
    - `X.Y.Z` → `X.Y.(Z+1)` (es. `0.6.4` → `0.6.5`).
    - Gli script di packaging (`./scripts/build-app.sh`, `./scripts/build-ios.sh`, ecc.) per impostazione predefinita applicano `--patch` ed eseguono automaticamente questo incremento.
    - **Non** usare `--no-bump` salvo che l'utente non richieda esplicitamente di non incrementare la versione; ogni ciclo/richiesta di build deve avanzare la Z di versione in modo che ogni nuovo artefatto prodotto abbia una versione progressiva e tracciabile.
  - Incrementi maggiori (`--minor` o `--major-fix`): avanzano `0.x.y` → `0.(x+1).0`.
  - `CFBundleVersion` è calcolato monotonicamente come `MAJOR*10000 + MINOR*100 + PATCH` (es. `0.6.5` → `605`).
- Benchmark output belongs under `.pyrowave-results/`, which is git ignored.

Useful commands:

```shell
swift run -c release pyrowave-swift-bench --preset 1080p --frames 60 --output-dir .pyrowave-results
swift run -c release pyrowave-swift-bench --preset 4k --frames 60 --output-dir .pyrowave-results
swift run -c release pyrowave-swift-bench --preset 6k --frames 60 --output-dir .pyrowave-results
```

When changing codec, Metal, `SPPW/1` transport/FEC, HEVC comparison, or benchmark code, run at least:

```shell
swift test -c release
```

If the only remaining work is validation, run the benchmark and save the report under `.pyrowave-results/`.

## Code Guidelines

- Prefer existing local types and patterns in `Sources/PyrowaveKit` and `Sources/SPPWCommon`.
- Keep GPU work explicit and inspectable in `Sources/PyrowaveKit/Metal/PyrowaveKernels.metal`.
- Avoid broad refactors while optimizing; isolate one performance hypothesis at a time.
- Keep generated benchmark reports and build artifacts out of git.
- Update `README.md` when architecture, build steps, benchmark policy, or headline results change.
- Update `PROTOCOL.md` when `SPPW/1` wire formats change.

## Validation Notes

Before reporting performance changes, compare:

- Pyrowave encode ms/frame
- Pyrowave decode ms/frame
- HEVC encode ms/frame
- HEVC decode ms/frame
- bytes/frame
- PSNR delta

Speedups above `1.0x` mean Pyrowave is faster than HEVC.
