# SPPW/1 Wire Protocol Specification

`SPPW/1` (*ScreenSpan PyroWire v1*) is the native UDP transport protocol used between `PyrowaveServerKit` (macOS/iOS Server) and `PyrowaveGUI` / `PyrowaveCastiOS` (macOS/iOS Receiver).

Source of truth:
- `Sources/PyrowaveServerKit/WireProtocol.swift`
- `Sources/SPPWCommon/SPPWFrameAssembler.swift`
- `Sources/SPPWCommon/SPPWForwardErrorCorrection.swift`
- `Sources/SPPWCommon/SPPWAudioInput.swift`
- `Sources/SPPWCommon/SPPWTransportSupport.swift`
- `Sources/SPPWCommon/SPPWSecurity.swift`, `Sources/SPPWCommon/SPPWSecurityPrimitives.swift` (secure transport, §7)

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
| `10` | `clipboard` | Bidirectional | Clipboard sync (`SPPWClipboardMessage`): subscription, item chunks, acknowledgements. macOS server in screen capture mode with remote control enabled; macOS and iOS receivers |
| `11` | `secureHello` | Client → Server | Secure handshake, plaintext (§7) |
| `12` | `secureReply` | Server → Client | Secure handshake, plaintext, signed (§7) |
| `13` | `secureAuth` | Bidirectional | Client signature and the server's admission decision, sealed (§7) |
| `14` | `pairing` | Bidirectional | PIN/password pairing (CPace), sealed (§7) |
| `15` | `secureNotice` | Server → Client | Unknown session or encryption setting mismatch, plaintext (§7) |

## 4. Header Flags (`flags`)

| Bit | Mask | Constant | Applies to | Meaning |
| --- | --- | --- | --- | --- |
| 0 | `0x0001` | `WireControlFlags.serverControlledResolution` | `serverHello`, `streamConfiguration` | Server enforces its own capture resolution |
| 1 | `0x0002` | `SPPWFragmentFlags.llCritical` | `frameFragment`, `fecParity` | Fragment belongs to coarse LL wavelet subband (`level == 4, band == 0`) |
| 2 | `0x0004` | `SPPWFragmentFlags.fecProtected` | `frameFragment`, `fecParity` | Frame carries Reed-Solomon FEC parity shards |
| 15 | `0x8000` | `SPPWSecureEnvelope.sealedFlag` | every kind except `11`, `12`, `15` | Payload is an AES-256-GCM envelope (§7) |

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
- A resync is a `streamConfiguration` with flag `0x0001`: the server replaces the control session and answers with a new `serverHello`, then resends the last frame. PyroWave frames are intra-only, so no keyframe exists or is needed. The capture is restarted only when the source is not running or produced nothing (not even idle callbacks) for 3 s; a new size or frame rate (from `streamConfiguration` or a reconnecting `clientHello`) is applied to the running ScreenCaptureKit stream in place. When the last client leaves (session timeout), the macOS server keeps the capture running for 10 s, so a client that reconnects within that time gets the same stream back.

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

**Host cursor.** `cursorVisibility` is state, not an injected event: in screen capture mode the server captures without the cursor (ScreenCaptureKit `showsCursor = false`, applied live with `updateConfiguration`) as long as at least one client asked for `hidden = 1`, whether or not remote input is enabled, and draws it again once none does or when that client leaves. It needs no Accessibility permission. Clients send it `sequenced` (or twice) and resend `hidden = 1` with every heartbeat and after each `serverHello`. The macOS receiver hides the host cursor while remote control is on (its local pointer sits exactly on the host position) and, with *Hide remote cursor*, also without remote control; the iOS receiver hides it in its fullscreen view, which draws its own pointer. The iOS receiver uses `pointerDelta`, `buttonAtCursor`, `clickAtCursor`, and `scroll` in trackpad mode and `touch` in direct touch mode.

### Clipboard (`kind = 10`, `SPPWClipboardMessage`)

16-byte header (big-endian) followed by chunk bytes:

| Offset | Size | Type | Field | Notes |
| --- | --- | --- | --- | --- |
| 0 | 1 | `UInt8` | `op` | `0` subscribe, `1` chunk, `2` ack |
| 1 | 1 | `UInt8` | `format` / `enabled` | chunk: `1` UTF-8 text (`<= 1 MiB`), `2` PNG (`<= 8 MiB`), `3` files (`<= 16 MiB`, container below), `4` file offer (`<= 4 MiB`, §8); subscribe: `0` off, `1` on |
| 2 | 2 | `UInt16` | `chunkIndex` | `< chunkCount` |
| 4 | 2 | `UInt16` | `chunkCount` | `>= 1` |
| 6 | 2 | `UInt16` | reserved | `0` |
| 8 | 4 | `UInt32` | `transferID` | chunk and ack |
| 12 | 4 | `UInt32` | `totalByteCount` | chunk |

- **Large files and folders (`format = 4`):** a Finder copy that contains a folder or more than 4 MiB of files is not sent inline: the clipboard carries a *file offer* and the data follows over the background transfer channel (§8).
- **Files container (`format = 3`, `SPPWClipboardFiles`, big-endian):** `UInt16 count` (1–64), then per file `UInt16 nameByteCount`, UTF-8 name, `UInt32 byteCount`, bytes; no trailing bytes. Names are single path components: `/`, `:`, `\`, and control characters become `_`, leading dots are removed, at most 255 bytes. Only regular files up to 4 MiB in total are sent inline; larger copies and folders go as a file offer (format 4). If an offer cannot be made (more than 20 000 entries, no listener), the copy is sent as its file names in UTF-8 text (as Finder itself puts them on the pasteboard), so the peer never keeps pasting an older item. A Mac writes received files to `<temporary>/PyrowaveCast Clipboard/<uuid>/` (previous items there are deleted), marks them quarantined like downloads, and puts their file URLs on the pasteboard, so pasting in Finder copies them; iOS puts one pasteboard item per file, typed by its extension. Peers that predate format 3 ignore those chunks (no ack), so the sender gives up after its retransmission rounds.
- **Subscription:** the receiver sends `subscribe` after every `serverHello` (and whenever the user toggles sync). The server only sends clipboard items to subscribed clients, and only while remote control is enabled in screen capture mode. What was on the Mac pasteboard before sync was turned on (server start, or remote control enabled) is not sent; anything copied since is. A client that subscribes (again) receives the current item if the pasteboard changed after sync started, so a copy made while it was reconnecting, when no client was subscribed and the poller was stopped, is not lost.
- **Transfer:** an item is split into chunks of `MTU − 40 − 16` bytes (each a separate datagram). The receiver keeps chunks in any order and answers `ack(transferID)` once the item is complete (again for duplicates). Chunks are paced (a 1 ms pause every 16 chunks, about 20 MB/s). Until acknowledged, the sender retransmits all chunks every 400 ms (stretched to 120 µs per chunk for large items, so rounds never pile up), for 5 rounds plus one per 500 chunks (at most 30); a newer item or the ack stops a round in progress, so a new copy never waits behind an older, larger one.
- **Loop prevention:** each side remembers a digest of the last item it sent or received and neither resends nor re-applies an identical item, so writing a received item to the pasteboard does not echo back.
- **macOS (server and receiver):** `NSPasteboard` `changeCount` polling every 500 ms; files (Finder copy) first, then text, then PNG/TIFF (sent as PNG). The macOS receiver syncs while remote control and its clipboard toggle are both on; unlike the server, it offers what is already on its own pasteboard when it subscribes, so something copied before connecting can be pasted on the remote Mac. Items marked `org.nspasteboard.ConcealedType`, `TransientType`, or `AutoGeneratedType` (password managers) are never sent.
- **iOS:** received items are written with `UIPasteboard` `localOnly` (no permission prompt; Universal Clipboard does not forward them back to the Mac). iPhone → Mac: while connected the receiver watches `UIPasteboard.changeCount` (once a second, on `UIPasteboard.changedNotification` and when the app becomes active; reading the counter never prompts) and reads each new copy once, which makes iOS show its "Allow Paste" prompt (every time, by design); its own writes are not read back. Files from the Files app (providers whose type is data or a folder but not text, a link or an image) are copied out of the provider and sent inline up to 4 MiB, otherwise as a file offer served from the iPhone (§8); then text, then images as PNG. Settings → *Remote control* → *Send iPhone copies automatically* turns this off (iPhone copies then stay on the iPhone). With Universal Clipboard active (same Apple ID, Handoff on) copies already travel by themselves; the digest check drops the duplicate.

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
   - Probing upward is inhibited until at least **5 seconds** of consecutive clean link operation (`minimumRampUpCooldownNanoseconds = 5_000_000_000`, the interval WebRTC GCC uses between probes).
   - Clean criteria: zero LL drops, zero expired frames, zero partial-HF frames, zero late drops, FEC recovery $< 5\%$, and jitter $< 20$ ms.
   - Probes increase bitrate by $10\%$ (minimum 2 Mb/s) towards the calculated ceiling (`width * height * 1.4 * quality * fps` rounded up to 1 Mb/s); below $80\%$ of the ceiling by $15\%$ and below $50\%$ by $25\%$, so the bitrate recovers quickly after a bad patch. After a failed probe, steps are $5\%$.
4. **Anti-Oscillation & Sticky Safe Ceiling:**
   - If link degradation occurs while probing a higher bitrate, ABR immediately reverts (`.revertToStable`) to the last problem-free bitrate and raises the cooldown to 20 seconds (40 seconds after two or more failed probes).
   - If the link fails again at or above this operating point (`failedProbeCount >= 2`), the controller locks `learnedSafeCeilingBps` (`isCeilingLocked = true`) to the stable bitrate, preventing oscillation on bandwidth-constrained or interference-penalized links. The lock is released after 30 s without impairment (Wi-Fi conditions change), with the 20 s backoff of one failed probe before the next probe.
   - A failed probe needs the same evidence as a step-down (heavy or persistent impairment); an isolated blip during a probe does not count.
5. **Seamless Server Application:**
   - The receiver transmits target updates via `kind = 5` (`.streamConfiguration`) with `flags = 0`.
   - Both macOS `StreamServer` and iOS `IOSStreamServer` apply the updated `maxBitrate` immediately to their frame budget (`maximumBitstreamBytes`) without stopping, recreating, or restarting ScreenCaptureKit / ReplayKit capture.

## 7. Secure Transport (encryption and pairing)

Optional, with a toggle on each side (**Encryption**, on by default). Both sides must agree: a server with encryption off answers a `secureHello` with `secureNotice(2)`, and a server with encryption on answers a plaintext `clientHello` with `secureNotice(1)`. Receivers report the mismatch to the user; a session is never silently downgraded. With encryption off on both sides the protocol is plain `SPPW/1` exactly as in §1–§6.

The layer sits on the UDP socket (`SPPWUDPServerSocket.security`, `SPPWUDPClientSocket.attachSecurity`; `SPPWClientSecurityBox` for the receivers' `NWConnection` fallback), so every message of §3–§6 keeps its format and the application code above it is unchanged.

### Identities and fingerprints

Every device has a long-term Ed25519 key (`identity.key`, created on first use). Its **fingerprint** is SHA-256 of the 32-byte public key, shown as the first 16 bytes in eight groups of four hex digits. Paired devices are stored as `trusted-clients.json` (on a server) and `trusted-servers.json` (on a receiver), with the headless password's salted PBKDF2 verifier in `server-password.json`; all files are `0600` in a `0700` folder: `~/Library/Application Support/PyrowaveCast/Security` on macOS, the app container on iOS (the `group.com.pyrowavecast.ios` App Group container when the signing profile grants it, so the broadcast extension shares the app's identity and pairings).

### Handshake (plaintext)

All integers big-endian; `name` is `UInt8 length` + UTF-8 (at most 64 bytes).

`secureHello` (kind 11): `UInt8 version (1)`, `UInt8 flags (0)`, 32-byte X25519 ephemeral key, 32-byte Ed25519 identity key, 16-byte nonce, `name`.

`secureReply` (kind 12): `UInt8 version`, `UInt8 pairingMode` (`0` open, `1` PIN, `2` password), `UInt8 clientKnown`, 32-byte X25519 ephemeral key, 32-byte Ed25519 identity key, 16-byte nonce, `name`, then a 64-byte Ed25519 signature by the server's identity key over `SHA-256(lp("SPPW/1 server signature") ‖ lp(hello payload) ‖ lp(reply body))`, where `lp(x)` is `UInt32 length ‖ x`.

Transcript `T = SHA-256(lp("SPPW/1 transcript") ‖ lp(hello payload) ‖ lp(reply payload))`. Keys: HKDF-SHA256 over the X25519 shared secret, salt `T`, info `"SPPW/1 session keys"`, 72 bytes = client→server key (32) ‖ server→client key (32) ‖ client→server nonce salt (4) ‖ server→client nonce salt (4). Retransmitted hellos (identical payload) get the identical reply; the client resends its last handshake message every 0.5 s until answered.

### Envelope (every later datagram)

`40-byte header (flags | 0x8000) ‖ UInt64 counter ‖ ciphertext ‖ 16-byte tag`, AES-256-GCM with nonce `salt ‖ counter` and the header plus counter as associated data. The header stays readable (routing, frame IDs) but cannot be changed. Counters start at 1 per direction; receivers accept each counter once within a window of the latest 1024 (reordering is fine, replays are dropped). Overhead: 24 bytes, within the 1200-byte datagram budget's margin. A sealed datagram from a sender without a session gets `secureNotice(0)`, and the receiver runs the handshake again (server restart).

### Admission (`secureAuth`, kind 13, sealed)

Client → server: 64-byte Ed25519 signature over `SHA-256(lp("SPPW/1 client signature") ‖ lp(T))`. Server → client: `UInt8 status` (`0` accepted, `1` pairing required), `UInt8 method` (`1` PIN, `2` password). A client is accepted when it is paired or the server is open. The receiver then trusts the server when its fingerprint is paired; an open server is used as *encrypted, unverified*; in every other case the receiver pairs first, so the server is verified too.

### Pairing (`pairing`, kind 14, sealed): CPace on X25519

`op` byte, then:

| op | Direction | Body |
| --- | --- | --- |
| `0` start | C → S | — |
| `1` challenge | S → C | `UInt8 method`, `UInt8 attemptsLeft`; for the password method also the 16-byte salt and `UInt32 iterations` of the server's PBKDF2 verifier |
| `2` clientShare | C → S | 32-byte share `Ya` |
| `3` serverShare | S → C | 32-byte share `Yb`, 32-byte `confirmServer` |
| `4` clientConfirm | C → S | 32-byte `confirmClient` |
| `5` result | S → C | `UInt8 code` (`0` paired, `1` wrong secret, `2` locked, `3` expired, `4` no password set), `UInt8 attemptsLeft` |

The secret is the 5-digit PIN (uniform `00000…99999`, shown on the server for 120 s, 3 guesses, then a new PIN; its UTF-8 digits are the CPace secret) or, for the password method, `PBKDF2-HMAC-SHA256(NFKC(password), salt, iterations, 32 bytes)`: the server stores only that value with its random salt (`server-password.json`, 200 000 iterations by default) and never the password; the receiver derives the same value from what the user types, accepting 10 000–2 000 000 iterations. 5 wrong passwords per client address and 30 in total per 5 minutes. Generator `G = Elligator2(SHA-512(lp("SPPW/1 CPace X25519") ‖ lp(secret) ‖ lp(T))[0..<32])` on Curve25519 (A = 486662, Z = 2, RFC 9380 §6.7.1); shares `Y = X25519(y, G)` with fresh random scalars; `K = X25519(y, Ypeer)` (all-zero results are refused); `ISK = SHA-512(lp("SPPW/1 CPace ISK") ‖ lp(T) ‖ lp(K) ‖ lp(Ya) ‖ lp(Yb))`; `confirmServer = HMAC-SHA256(ISK, lp("SPPW/1 pairing server") ‖ lp(T))`, `confirmClient` likewise with `"SPPW/1 pairing client"`. Both sides learn whether the other used the same secret; a wrong guess teaches an attacker nothing about the secret, so every guess needs a live exchange with the server and counts against the limits above. `T` binds the pairing to both identity keys and this handshake, so it cannot be relayed into another session. On `result(0)` both sides store the other's identity key; later sessions need no PIN. The receiver stores the server only if `confirmServer` checked out, so a server that answers *paired* without knowing the secret is rejected.

The server answers duplicate requests (UDP retransmissions) from cache, so a repeated share never costs a second guess.

### Modes

- **PIN** (default): a new receiver pairs with the PIN shown on the server (macOS window, iOS server screen, `pyrowave-server` terminal; the iOS broadcast extension writes it to the App Group for the app to show).
- **Password**: for headless servers. Set with `pyrowave-server --set-password` (or `--password-file`, or the server UI), then `--pairing password`.
- **Open**: any receiver is accepted, still encrypted, but nobody is verified. The iOS broadcast extension uses it when no App Group is available, because it has no screen to show a PIN.

## 8. Background File Transfer (large clipboard items)

Started only on demand, for a copy with folders or more than 4 MiB of files (`SPPWBackgroundTransfer.swift`), and closed when done. The media path is untouched: the data goes over TCP, not over the `SPPW/1` UDP socket.

**Offer** (clipboard `format = 4`, travels on the clipboard channel, so it is sealed when §7 encryption is on): `16-byte token ‖ 32-byte key ‖ UInt16 TCP port ‖ UInt32 entryCount`, then per entry `UInt8 isDirectory ‖ UInt16 pathBytes ‖ UTF-8 path ‖ UInt64 size`. Paths are relative, `/`-separated, and every component passes the same sanitising as file names (no `.`/`..`, no `/`, `:`, `\`, control characters, no leading dot); symbolic links are skipped. At most 20 000 entries; sizes are 64-bit (no practical size limit beyond disk space). Top-level entries are the copied items.

**Listener:** the side that copied opens a TCP listener (`NWListener`, any port, Network.framework service class *background*, i.e. the Wi-Fi background access category) for that offer only. It closes after the downloader's `done`, when a newer copy replaces it (at most 3 open offers), or after 30 minutes. The downloader connects to the address it already uses for `SPPW/1` (the server's host, or the client's address as seen by the server).

**Records:** `UInt32 length ‖ AES-256-GCM(ciphertext ‖ 16-byte tag)` with the offer's key and nonce `direction (4 bytes, "DPWU" downloader→sender / "UPWD" sender→downloader) ‖ UInt64 counter` (1, 2, … per connection and direction). A record that fails to open ends the connection.

| Type | Direction | Body |
| --- | --- | --- |
| `0` hello | D → S | 16-byte token (first record; anything else closes the connection) |
| `1` get | D → S | `UInt32 entryIndex`, `UInt64 offset` |
| `2` data | S → D | `UInt32 entryIndex`, `UInt64 offset`, up to 256 KiB of bytes |
| `3` endOfEntry | S → D | `UInt32 entryIndex` |
| `4` failure | S → D | `UInt8 code` (`1` entry unreadable) |
| `5` done | D → S | — (all entries received; the listener closes) |

The downloader asks for one file at a time, creates folders itself, and writes each piece straight to disk (nothing is held whole in memory, on either side). The sender reads 256 KiB at a time and sends the next piece only after the network accepted the previous one, paced to at most 25 MiB/s. After a dropped connection the downloader reconnects (up to 8 times, 1–5 s apart) and asks from the bytes already on disk; three connections closed before any record arrived (wrong key or token, or the offer is gone) end the transfer. Received files are quarantined like downloads on macOS.

**Receivers of an offer:**
- **macOS** puts the top-level names on the pasteboard as text at once (so an older item is never pasted), downloads everything into `<temporary>/PyrowaveCast Transfers/<uuid>/`, and then replaces the names with the files, unless something else was copied in the meantime. Finder pastes from the pasteboard do not take file promises reliably, so the download is eager rather than deferred.
- **iOS** registers one lazy `NSItemProvider` per top-level entry (`localOnly`, valid as long as the offer): nothing is downloaded until an app pastes it, then only that entry (with a folder's contents) streams in, with progress in the system paste UI.

Both servers' and receivers' windows (macOS) list running transfers with progress and a cancel button. Measured on loopback (M2 Pro): 64 MiB plus a small folder tree in 2.9 s, i.e. the 25 MiB/s cap (about 41 s per GiB).

