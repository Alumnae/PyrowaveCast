# SPPW/1 Wire Protocol Specification

`SPPW/1` (*ScreenSpan PyroWire v1*) is the native UDP transport protocol used between `PyrowaveServerKit` (macOS/iOS Server) and `PyrowaveGUI` / `PyrowaveCastiOS` (macOS/iOS Receiver).

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
| 16 | 2 | `UInt16` | `width` | Frame width in pixels (even) |
| 18 | 2 | `UInt16` | `height` | Frame height in pixels (even) |
| 20 | 2 | `UInt16` | `fragmentIndex` | Fragment index (`0..<fragmentCount`), or parity index for `.fecParity` |
| 22 | 2 | `UInt16` | `fragmentCount` | Total data fragments in the frame |
| 24 | 4 | `UInt32` | `frameByteCount` | Total encoded bitstream size of the frame |
| 28 | 8 | `UInt64` | `senderTimestampNanoseconds` | Monotonic sender uptime (ns, `mach_absolute_time` clock). For `frameFragment`/`fecParity` it is the frame's **capture** instant, for `audioFrame` the capture instant of the packet's first sample (see *Audio/video sync*) |
| 36 | 4 | `UInt32` | `payloadChecksum` | Reserved, unused. Senders write `0`; receivers ignore it (integrity comes from UDP checksums and Reed-Solomon FEC) |

### Audio/video sync

Video and audio share one sender clock: servers stamp each video frame with the instant it was captured (ScreenCaptureKit / ReplayKit presentation time on the host clock) and each 5 ms audio packet with the capture instant of its first sample. Encode and send time are not part of the stamp.

Receivers measure the video path, `videoDelay = presentedAt − senderTimestamp` (smoothed; it also absorbs the unknown offset between the two devices' clocks), and aim to have every audio packet heard at `senderTimestamp + videoDelay + displayLatency`. Video is never delayed for audio. A jitter buffer (`SPPWAudioJitterController`) turns that target into a desired queue depth, clamped between a minimum (20 ms + two device IO buffers + the network allowance below) and 200 ms; when audio's own path is slower than video, the depth simply stays at the minimum and nothing is dropped. The measured depth is smoothed (packets arrive in bursts) and corrected at most every 500 ms, by dropping one 5 ms packet or inserting at most 10 ms of fill, only when it is more than 25 ms off. Packets are played in `sequence` order; late or duplicate packets are discarded. Without video in the last second, audio plays at the minimum depth.

Servers hand audio packets from the capture thread to a single ordered sender (`SPPWOrderedPacketQueue`), so they leave in capture order.

**Wi-Fi resilience (receiver only, no wire change).** The jitter buffer's minimum depth adds a *network allowance*: each packet's transit (`arrival − senderTimestamp`, the constant clock offset cancels) is compared with the fastest recent transit, and the peak of that spike rises at once and decays with a ≈ 4 s half-life (capped at 120 ms). One Wi-Fi stall therefore deepens the buffer for the next few seconds instead of starving it again. The desired depth and the measured queue are smoothed slowly (2 % per packet) and corrected at most every 500 ms, only beyond 25 ms. Gaps of up to 8 lost packets are filled with a faded repeat of the previous packet (keeping the timeline, so no later correction is needed), and every packet after a cut (gap, drop, inserted silence) fades in over 2 ms instead of clicking.

**Video pacing.** Servers spread each frame's datagrams over 80 % of the frame interval (at most 14 ms) in bursts of 4, which keeps the peak rate a Wi-Fi access point has to absorb close to the average bitrate. When the next frame is ready before the current one is fully sent, the current frame is finished at full speed if it started less than one frame interval ago (uneven capture timing); only a real backlog has its trailing HF datagrams pre-empted.

### Chroma subsampling

The chroma mode is not an `SPPW/1` field: it travels in the PyroWave sequence header of every frame. Servers send 4:2:0 by default; the macOS server sends 4:4:4 when started with full colour enabled. Receivers inspect the sequence header of each assembled frame and rebuild their decoder when the mode changes (NV12 output for 4:2:0, BGRA for 4:4:4). The coarse LL subband (`level == 4, band == 0`) has the same block layout in both modes, so `llCritical` tagging and partial-HF salvage are unchanged.

## 3. Message Kinds (`kind`)

| Value | Name | Direction | Purpose |
| --- | --- | --- | --- |
| `1` | `clientHello` | Client → Server | Initiate session with 22-byte `ClientConfiguration` payload |
| `2` | `serverHello` | Server → Client | Acknowledge session, assign `streamID` and effective resolution/FPS |
| `3` | `frameFragment` | Server → Client | Fragment of an upstream PyroWave v1 bitstream (4:2:0 or 4:4:4, see below) |
| `4` | `input` | Client → Server | Remote pointer, mouse, scroll, keyboard, touch, or release-all event (`SPPWInputEvent`) |
| `5` | `streamConfiguration` | Bidirectional | Reconfigure resolution, FPS, bitrate, FEC, MTU; server replies with ACK |
| `6` | `ping` | Client → Server | Keep-alive / stream start trigger |
| `7` | `pong` | Server → Client | Keep-alive reply |
| `8` | `fecParity` | Server → Client | Cauchy Reed-Solomon GF(2^8) parity shard (`SPPWFECBlockHeader` + parity bytes) |
| `9` | `audioFrame` | Server → Client | 48 kHz stereo PCM16 audio chunk (`SPPWAudioPacketHeader` + samples); sent by the macOS and iOS servers in screen capture mode (system audio or a microphone) and video file mode (the file's audio track) |
| `10` | `clipboard` | Bidirectional | Clipboard sync (`SPPWClipboardMessage`): subscription, item chunks, acknowledgements. macOS server in screen capture mode with remote control enabled |

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
| 0 | 2 | `UInt16` | `width` | `0` with `height = 0`: native; `0` with `height = S`: short side `S` (see *Resolution requests*); otherwise legacy explicit width, clamped to even `<= 3840` |
| 2 | 2 | `UInt16` | `height` | Short side in lines when `width = 0` (`2160, 1440, 1080, 720, 480, 360, 320`); otherwise legacy explicit height, clamped to even `<= 2160` |
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

### Resolution requests

The client chooses the stream size relative to the server's native size (`SPPWResolutionLadder`):

- `0 × 0` — native: the server's screen size in screen capture mode (capped at 3840×2160), 1920×1080 for generated test content.
- `0 × S` — short side `S`: the shorter dimension becomes `S` lines and the longer one follows the server's aspect ratio (16:9, 16:10, iPhone, iPad, landscape or portrait); never larger than native. Test content uses 16:9.
- `W × H` — legacy explicit size: fitted inside `W × H` keeping the server's aspect ratio.

The server answers with the resolved size in the `width`/`height` header fields of `serverHello` / the `streamConfiguration` ack. The macOS server lets ScreenCaptureKit scale the capture; the iOS server scales captured frames on the GPU (`VTPixelTransferSession`). The receiver's *Automatic* mode is client-side: it moves one level down when the adaptive bitrate stays below half the current level's ceiling for 3 s, and one level up after holding the ceiling for 15 s (doubling after a failed step-up, up to 120 s).

### Still screens and resync

- A server resends its last encoded frame (same bitstream, new `frameID` and timestamp) when no frame went out for 1 s (`SPPWStillScreenPolicy`), because screen capture delivers nothing while the screen is unchanged. Receivers therefore treat 2 s without a frame (4 s before the first frame of a session) as a lost stream.
- A resync is a `streamConfiguration` with flag `0x0001`: the server replaces the control session and answers with a new `serverHello`, then resends the last frame. PyroWave frames are intra-only, so no keyframe exists or is needed. The capture is restarted only when the source is not running, the size or rate changed, or the capture produced nothing (not even idle callbacks) for 3 s.

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
| `6` | `releaseAll` | No payload (1 B total); instructs the server to release all currently held mouse buttons, keys, and modifier flags |
| `7` | `text` | `UInt16 byteCount` (`<= 1024`), UTF-8 bytes. Committed Unicode text, typed with `CGEventKeyboardSetUnicodeString` (chunks of at most 20 UTF-16 units, never splitting a character); `\n`/`\r` become Return and `\t` Tab key taps |
| `8` | `keyPress` | `UInt16 keyCode`, `UInt32 modifiers` (7 B total). Atomic key tap (down + up) |
| `9` | `pointerDelta` | `Float deltaX`, `Float deltaY` (9 B total). Relative motion in host display points, clamped to the streamed display; drags while a button is held |
| `10` | `buttonAtCursor` | `UInt8 button`, `UInt8 isDown` (3 B total). Press/release at the current cursor position |
| `11` | `clickAtCursor` | `UInt8 button` (2 B total). Atomic click at the cursor; presses within 500 ms and 6 pt count as double/triple clicks |
| `12` | `sequenced` | `UInt16 sequence`, then one complete inner event (not itself `sequenced`) |
| `13` | `cursorVisibility` | `UInt8 hidden` (`1` = leave the host cursor out of the video, `0` = draw it) |

Key codes are macOS virtual key codes (`kVK_*`, ANSI positions). `modifiers` uses the `CGEventFlags` device-independent bits: `0x00010000` Caps Lock, `0x00020000` Shift, `0x00040000` Control, `0x00080000` Option, `0x00100000` Command, `0x00200000` numeric pad, `0x00800000` Fn. The server adds the bits a real Apple keyboard sets on its own (numeric pad + Fn on arrows, Fn on F-keys and Home/End/Page Up/Page Down/Forward Delete), so system shortcuts such as Mission Control (`⌃↑`) match. A second `key` down for a key already held is posted as auto-repeat.

**Text vs key codes (IME).** Receivers send text composed on the device — IME composition such as Chinese Pinyin or Japanese Kana, accented characters, emoji, dictation — only once it is committed, as `text`. Marked (in-progress) text never leaves the device. Typing Unicode is independent of the Mac's keyboard layout and input source, which would otherwise re-interpret key codes. Keys that are not text (arrows, Esc, Tab, F-keys, Page Up/Down) and shortcuts (a character typed with Command, Control or Option, mapped to its US-ANSI key) are sent as key codes with modifier flags (`keyPress`, or `key` down/up for hardware keyboards), because applications match shortcuts on key codes. Shift alone with a character is sent as the uppercased text.

**Reliability.** Discrete events (`text`, `keyPress`, `key`, `mouseButton`, `buttonAtCursor`, `clickAtCursor`, `releaseAll`) are wrapped in `sequenced` and sent twice, about 12 ms apart. The server keeps the last 256 sequence numbers per client and applies each one once. Motion and scroll events are sent once.

**Host cursor.** `cursorVisibility` is state, not an injected event: while remote input is enabled, the server captures without the cursor (ScreenCaptureKit `showsCursor = false`, applied live with `updateConfiguration`) as long as at least one client asked for `hidden = 1`, and draws it again once none does, when remote input is disabled, or when that client leaves. It needs no Accessibility permission. Clients send it `sequenced` (or twice) and resend `hidden = 1` with every heartbeat and after each `serverHello`. The macOS receiver hides the host cursor while remote control is on (its local pointer sits exactly on the host position); the iOS receiver hides it only in direct-touch mode without a hardware mouse. The iOS receiver uses `pointerDelta`, `buttonAtCursor`, `clickAtCursor`, and `scroll` in trackpad mode and `touch` in direct touch mode.

### Clipboard (`kind = 10`, `SPPWClipboardMessage`)

16-byte header (big-endian) followed by chunk bytes:

| Offset | Size | Type | Field | Notes |
| --- | --- | --- | --- | --- |
| 0 | 1 | `UInt8` | `op` | `0` subscribe, `1` chunk, `2` ack |
| 1 | 1 | `UInt8` | `format` / `enabled` | chunk: `1` UTF-8 text (`<= 1 MiB`), `2` PNG (`<= 8 MiB`); subscribe: `0` off, `1` on |
| 2 | 2 | `UInt16` | `chunkIndex` | `< chunkCount` |
| 4 | 2 | `UInt16` | `chunkCount` | `>= 1` |
| 6 | 2 | `UInt16` | reserved | `0` |
| 8 | 4 | `UInt32` | `transferID` | chunk and ack |
| 12 | 4 | `UInt32` | `totalByteCount` | chunk |

- **Subscription:** the receiver sends `subscribe` after every `serverHello` (and whenever the user toggles sync). The server only sends clipboard items to subscribed clients, and only while remote control is enabled in screen capture mode. What is already on the Mac pasteboard when a client subscribes is not sent; only later changes are.
- **Transfer:** an item is split into chunks of `MTU − 40 − 16` bytes (each a separate datagram). The receiver keeps chunks in any order and answers `ack(transferID)` once the item is complete (again for duplicates). Until acknowledged, the sender retransmits all chunks every 400 ms, at most 5 rounds; a newer item replaces one still in flight.
- **Loop prevention:** each side remembers a digest of the last item it sent or received and neither resends nor re-applies an identical item, so writing a received item to the pasteboard does not echo back.
- **macOS:** `NSPasteboard` `changeCount` polling every 500 ms; text first, then PNG/TIFF (sent as PNG). Items marked `org.nspasteboard.ConcealedType`, `TransientType`, or `AutoGeneratedType` (password managers) are never sent.
- **iOS:** received items are written with `UIPasteboard` `localOnly` (no permission prompt; Universal Clipboard does not forward them back to the Mac). The pasteboard is only read on an explicit user action, through the system paste control in the remote control dock, which iOS allows without the paste prompt. With Universal Clipboard active (same Apple ID, Handoff on) copies already travel by themselves; the digest check drops the duplicate.

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
2. **Step-Down on Congestion, not on Wi-Fi Blips:**
   - Wi-Fi loses isolated packets and stalls for tens of milliseconds (retries, AWDL, power save, scans) without being short of capacity, so a single impaired second (one lost/expired frame, one or two partial-HF frames, one late drop) only holds the bitrate and restarts the clean timer.
   - **Severe** — heavy loss in one second (LL drops + expired frames $\ge 3\%$ of frames, or $\ge 3$ late drops), or loss in at least two impaired seconds within 3 s: bitrate reduced by factor $0.80$ (minimum step $\ge 2$ Mb/s).
   - **Moderate** — partial-HF frames $\ge 10\%$ (or $\ge 5\%$ with jitter $\ge 25$ ms), FEC recovery $> 35\%$, or persistent partial-HF / FEC recovery $> 20\%$ within 3 s: bitrate reduced by factor $0.90$ (minimum step $\ge 1$ Mb/s).
   - Bitrate steps down every second while the condition lasts, down to a floor of 5 Mb/s.
3. **Cautious Ramp-Up Hold ($\ge 10$ seconds):**
   - Probing upward is inhibited until at least **10 seconds** of consecutive clean link operation (`minimumRampUpCooldownNanoseconds = 10_000_000_000`).
   - Clean criteria: zero LL drops, zero expired frames, zero partial-HF frames, zero late drops, FEC recovery $< 5\%$, and jitter $< 20$ ms.
   - Probes increase bitrate by $10\%$ (minimum 2 Mb/s) towards the calculated ceiling (`width * height * 1.4 * quality * fps` rounded up to 1 Mb/s); below $80\%$ of the ceiling by $15\%$ and below $50\%$ by $25\%$, so the bitrate recovers quickly after a bad patch. After a failed probe, steps are $5\%$.
4. **Anti-Oscillation & Sticky Safe Ceiling:**
   - If link degradation occurs while probing a higher bitrate, ABR immediately reverts (`.revertToStable`) to the last problem-free bitrate and doubles cooldown to 20 seconds.
   - If the link fails again at or above this operating point (`failedProbeCount >= 2`), the controller locks `learnedSafeCeilingBps` (`isCeilingLocked = true`) to the stable bitrate, preventing oscillation on bandwidth-constrained or interference-penalized links. The lock is released after 120 s without impairment (Wi-Fi conditions change), with the 20 s backoff of one failed probe before the next probe.
   - A failed probe needs the same evidence as a step-down (heavy or persistent impairment); an isolated blip during a probe does not count.
5. **Seamless Server Application:**
   - The receiver transmits target updates via `kind = 5` (`.streamConfiguration`) with `flags = 0`.
   - Both macOS `StreamServer` and iOS `IOSStreamServer` apply the updated `maxBitrate` immediately to their frame budget (`maximumBitstreamBytes`) without stopping, recreating, or restarting ScreenCaptureKit / ReplayKit capture.
