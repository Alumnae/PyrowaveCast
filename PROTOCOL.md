# SPPW/1 Wire Protocol Specification

`SPPW/1` (*ScreenSpan PyroWire v1*) is the native UDP transport protocol used between `PyrowaveServerKit` (macOS/iOS Server) and `PyrowaveGUI` / `iPyroServer` (macOS/iOS Receiver).

Source of truth:
- `Sources/PyrowaveServerKit/WireProtocol.swift`
- `Sources/SPPWCommon/SPPWFrameAssembler.swift`
- `Sources/SPPWCommon/SPPWForwardErrorCorrection.swift`
- `Sources/SPPWCommon/SPPWAudioInput.swift`
- `Sources/SPPWCommon/SPPWTransportSupport.swift`

## 1. Transport & Discovery

- **Transport:** Pure unicast UDP (dual-stack POSIX sockets with DSCP CS4 `0x80` / WMM `AC_VI`, explicit `SO_SNDBUF`/`SO_RCVBUF` sizing, and `mach_wait_until` micro-burst pacing).
- **Default port:** `9888/UDP`
- **Discovery:** Bonjour / mDNS service `_pyrowave._udp`
- **Byte order:** Big-endian for all protocol headers and fields (PCM16 audio samples are little-endian `Int16`).
- **Session timeout:** 30 seconds of client inactivity.

## 2. Common Datagram Header (40 bytes)

Every `SPPW/1` datagram starts with a fixed 40-byte header (`WireHeader` / `SPPWDatagramHeader`):

| Offset | Size | Type | Field | Notes |
| --- | --- | --- | --- | --- |
| 0 | 4 | `UInt32` | `magic` | `0x53505057` (`"SPPW"`) |
| 4 | 1 | `UInt8` | `version` | `1` |
| 5 | 1 | `UInt8` | `kind` | See Message Kinds below |
| 6 | 2 | `UInt16` | `flags` | Control / fragment bitmask |
| 8 | 4 | `UInt32` | `streamID` | Control or shared media stream ID |
| 12 | 4 | `UInt32` | `frameID` | Monotonic video frame counter |
| 16 | 2 | `UInt16` | `width` | Frame width in pixels (even, 4:2:0) |
| 18 | 2 | `UInt16` | `height` | Frame height in pixels (even, 4:2:0) |
| 20 | 2 | `UInt16` | `fragmentIndex` | Fragment index (`0..<fragmentCount`), or parity index for `.fecParity` |
| 22 | 2 | `UInt16` | `fragmentCount` | Total data fragments in the frame |
| 24 | 4 | `UInt32` | `frameByteCount` | Total encoded bitstream size of the frame |
| 28 | 8 | `UInt64` | `senderTimestampNanoseconds` | Monotonic sender uptime (ns) |
| 36 | 4 | `UInt32` | `payloadChecksum` | Reserved, unused. Senders write `0`; receivers ignore it (integrity comes from UDP checksums and Reed-Solomon FEC) |

## 3. Message Kinds (`kind`)

| Value | Name | Direction | Purpose |
| --- | --- | --- | --- |
| `1` | `clientHello` | Client → Server | Initiate session with 22-byte `ClientConfiguration` payload |
| `2` | `serverHello` | Server → Client | Acknowledge session, assign `streamID` and effective resolution/FPS |
| `3` | `frameFragment` | Server → Client | Fragment of an upstream PyroWave v1 bitstream |
| `4` | `input` | Client → Server | Remote pointer, mouse, scroll, keyboard, or touch event (`SPPWInputEvent`) |
| `5` | `streamConfiguration` | Bidirectional | Reconfigure resolution, FPS, bitrate, FEC, MTU; server replies with ACK |
| `6` | `ping` | Client → Server | Keep-alive / stream start trigger |
| `7` | `pong` | Server → Client | Keep-alive reply |
| `8` | `fecParity` | Server → Client | Cauchy Reed-Solomon GF(2^8) parity shard (`SPPWFECBlockHeader` + parity bytes) |
| `9` | `audioFrame` | Server → Client | 48 kHz stereo PCM16 audio chunk (`SPPWAudioPacketHeader` + samples) |

## 4. Header Flags (`flags`)

| Bit | Mask | Constant | Applies to | Meaning |
| --- | --- | --- | --- | --- |
| 0 | `0x0001` | `WireControlFlags.serverControlledResolution` | `serverHello`, `streamConfiguration` | Server enforces its own capture resolution |
| 1 | `0x0002` | `SPPWFragmentFlags.llCritical` | `frameFragment`, `fecParity` | Fragment belongs to coarse LL wavelet subband (`level == 4, band == 0`) |
| 2 | `0x0004` | `SPPWFragmentFlags.fecProtected` | `frameFragment`, `fecParity` | Frame carries Reed-Solomon FEC parity shards |

## 5. Payload Formats

### Client Configuration (`clientHello` / `streamConfiguration`, 22 bytes)

| Offset | Size | Type | Field | Notes |
| --- | --- | --- | --- | --- |
| 0 | 2 | `UInt16` | `width` | `0` = server default; clamped to even `<= 3840` |
| 2 | 2 | `UInt16` | `height` | `0` = server default; clamped to even `<= 2160` |
| 4 | 2 | `UInt16` | `fps` | Clamped `1...120` |
| 6 | 1 | `UInt8` | `automaticBitrate` | `0` = false, non-zero = true |
| 7 | 1 | `UInt8` | `latencyMode` | Latency profile |
| 8 | 4 | `UInt32` | `maxBitrate` | Bits/sec (`1_000_000...1_000_000_000`) |
| 12 | 2 | `UInt16` | `quality` | Scaled by `10_000` (`0.01...1.0`) |
| 14 | 2 | `UInt16` | `fecPercent` | Parity target (`0...100`) |
| 16 | 2 | `UInt16` | `mtu` | Datagram budget (`256...9000`, default `1200`) |
| 18 | 2 | `UInt16` | `frameTimeoutMs` | Receiver assembly timeout (ms) |
| 20 | 1 | `UInt8` | `maxBufferedFrames` | Frame queue limit |
| 21 | 1 | `UInt8` | `colorRange` | Video color range flag |

### Asymmetric LL/HF FEC Parity (`kind = 8`)

`WireHeader.fragmentIndex` carries the parity index (`0..<blockParityCount`) within the FEC block, and `WireHeader.fragmentCount` carries the total data fragment count of the frame.

Payload begins with the 8-byte `SPPWFECBlockHeader`, followed by `shardPayloadSize` bytes of GF(2^8) parity data:

| Offset | Size | Type | Field |
| --- | --- | --- | --- |
| 0 | 2 | `UInt16` | `blockStartFragment` |
| 2 | 2 | `UInt16` | `blockDataCount` ($K$, `1...64`) |
| 4 | 2 | `UInt16` | `blockParityCount` ($M$, `1...64`) |
| 6 | 2 | `UInt16` | `shardPayloadSize` |

- **LL-critical policy:** `SPPWPyrowaveSubbandInspector` finds the byte boundary of the coarse LL subband (`level == 4, band == 0`), which sits at the start of the PyroWave bitstream. LL fragments receive `llCritical` and heavier parity (`>= 25%`, `>= 2` shards).
- **Receiver recovery:** Missing unrecoverable LL fragments trigger an immediate drop of the stale frame when a newer frame arrives; if LL is intact and only trailing HF fragments are lost, `SPPWFrameAssembler` salvages the valid block-aligned prefix for partial-HF GPU decode.

### Audio Frame (`kind = 9`)

8-byte `SPPWAudioPacketHeader` followed by interleaved little-endian `Int16` PCM samples (default: 240 frames = 5 ms stereo @ 48 kHz = 960 bytes):

| Offset | Size | Type | Field |
| --- | --- | --- | --- |
| 0 | 4 | `UInt32` | `sequence` |
| 4 | 2 | `UInt16` | `frameCount` |
| 6 | 1 | `UInt8` | `channels` (`1` or `2`) |
| 7 | 1 | `UInt8` | `formatFlags` (`0` = interleaved `Int16` LE @ 48 kHz) |

### Remote Input (`kind = 4`, `SPPWInputEvent`)

First byte is the event tag; coordinates `normalizedX`/`normalizedY` are IEEE-754 big-endian `Float` in `[0, 1]`:

| Tag | Event | Payload Layout |
| --- | --- | --- |
| `1` | `pointerMove` | `Float normalizedX`, `Float normalizedY` (9 B total) |
| `2` | `mouseButton` | `UInt8 button`, `UInt8 isDown`, `Float normalizedX`, `Float normalizedY` (11 B total) |
| `3` | `scroll` | `Float deltaX`, `Float deltaY` (9 B total) |
| `4` | `key` | `UInt16 keyCode`, `UInt8 isDown`, `UInt32 modifiers` (8 B total) |
| `5` | `touch` | `UInt8 count` (`<= 16`), repeated `count` times: `UInt32 id`, `UInt8 phase` (`0`=began, `1`=moved, `2`=ended, `3`=cancelled), `Float normalizedX`, `Float normalizedY` |

## 6. Closed-Loop Adaptive Bitrate (ABR)

When `automaticBitrate` is enabled in `ClientConfiguration`:

1. **Receiver Metric Sampling (1-second cadence):**
   - The receiver executes `SPPWAdaptiveBitrateController` on a 1-second interval (`evaluationIntervalNanoseconds = 1_000_000_000`).
   - Every second, it samples:
     - Delta of completed frames (`completeFramesDelta`)
     - Delta of LL-dropped frames (`llDroppedFramesDelta`)
     - Delta of expired frames (`expiredFramesDelta`)
     - Delta of partial-HF decoded frames (`partialHFFramesDelta`)
     - Delta of FEC-recovered frames (`fecRecoveredFramesDelta`)
     - Delta of late-dropped frames (`lateDroppedFramesDelta`)
     - Smoothed RFC 3550 inter-arrival jitter (`jitterMs`)
2. **Immediate Step-Down on Link Degradation:**
   - **Severe** (LL drops, expired frames, $\ge 2$ late drops): bitrate reduced by factor $0.75$ (minimum step $\ge 2$ Mb/s).
   - **Moderate** ($\ge 2$ partial-HF frames, FEC recovery $> 20\%$, or jitter $\ge 25$ ms with packet drops): bitrate reduced by factor $0.85$ (minimum step $\ge 1$ Mb/s).
   - Bitrate steps down consecutively every 1 second until degradation clears, down to a floor of 5 Mb/s.
3. **Cautious Ramp-Up Hold ($\ge 10$ seconds):**
   - Probing upward is inhibited until at least **10 seconds** of consecutive clean link operation (`minimumRampUpCooldownNanoseconds = 10_000_000_000`).
   - Clean criteria: zero LL drops, zero expired frames, zero partial-HF frames, zero late drops, FEC recovery $< 5\%$, and jitter $< 20$ ms.
   - Probes increase bitrate cautiously by $10\%$ (minimum 2 Mb/s) towards the calculated ceiling (`width * height * 1.4 * quality * fps` rounded up to 1 Mb/s).
4. **Anti-Oscillation & Sticky Safe Ceiling:**
   - If link degradation occurs while probing a higher bitrate, ABR immediately reverts (`.revertToStable`) to the last problem-free bitrate and doubles cooldown to 20 seconds.
   - If the link fails again at or above this operating point (`failedProbeCount >= 2`), the controller locks `learnedSafeCeilingBps` (`isCeilingLocked = true`) to the stable bitrate, permanently preventing oscillation on bandwidth-constrained or interference-penalized links.
5. **Seamless Server Application:**
   - The receiver transmits target updates via `kind = 5` (`.streamConfiguration`) with `flags = 0`.
   - Both macOS `StreamServer` and iOS `IOSStreamServer` apply the updated `maxBitrate` immediately to their frame budget (`maximumBitstreamBytes`) without stopping, recreating, or restarting ScreenCaptureKit / ReplayKit capture.
