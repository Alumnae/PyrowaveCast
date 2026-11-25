# PyrowaveCast Privacy Policy

PyrowaveCast (iOS, iPadOS and macOS) streams the screen, sound and input of your devices to other devices you choose on your local network. It is built so that nothing leaves your own devices.

## Data we collect

None. PyrowaveCast has no accounts, no analytics, no advertising, no crash reporting service and no servers of its own. The developer never receives video, audio, keystrokes, clipboard contents, files, device names or any other information from the app.

## What stays on your devices

- **Settings** (ports, resolution, language, favourite servers and similar) are stored locally on the device.
- **Pairing keys** (when encryption is on) are generated on the device and kept in the app's private storage. They identify your paired devices to each other and are never sent anywhere else.
- **Received clipboard items and files** are kept in the app's temporary folder until they are replaced or the system clears them.

## What travels between your devices

When you start a server or connect a receiver, PyrowaveCast sends the screen video, the sound, and (if you enable it) keyboard, mouse and clipboard data directly between the two devices over your local network, using the SPPW/1 protocol. When encryption is on, this traffic is protected with AES-256-GCM and the devices authenticate each other with keys created at pairing. No third party, including the developer, is involved.

## Permissions

- **Local network:** to find servers with Bonjour and to stream over UDP.
- **Screen recording / screen broadcast:** only while you share the screen.
- **Microphone:** only if you choose a microphone as the stream's audio source.
- **Accessibility (macOS, download from GitHub only):** only if you allow receivers to control the Mac's mouse and keyboard. The Mac App Store version never asks for it.

You can withdraw any permission at any time in Settings (iOS, iPadOS) or System Settings → Privacy & Security (macOS).

## Children

PyrowaveCast does not collect personal information from anyone, including children.

## Changes

Any change to this policy will be published in this file, in the project's public repository.

## Contact

Questions about privacy: open an issue in the project's GitHub repository.

_Last updated: 25 November 2026_
