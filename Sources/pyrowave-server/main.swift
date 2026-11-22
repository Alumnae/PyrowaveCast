import Foundation
import Network
import PyrowaveServerKit

// MARK: - Main entry point

let defaultPort: UInt16 = 9888

var requestedPort = defaultPort
var testMode = false
var testImagePath: String?
var testVideoPath: String?
let args = CommandLine.arguments.dropFirst()
var argIter = args.makeIterator()
while let arg = argIter.next() {
    if arg == "--port" || arg == "-p" {
        if let portStr = argIter.next(), let p = UInt16(portStr) {
            requestedPort = p
        }
    } else if arg == "--test" {
        testMode = true
    } else if arg == "--test-image" {
        if let path = argIter.next() {
            testImagePath = path
            testMode = true
        }
    } else if arg == "--test-video" {
        if let path = argIter.next() {
            testVideoPath = path
            testMode = true
        }
    } else if arg == "--help" || arg == "-h" {
        print("""
        PyrowaveKit SPPW/1 Server

        Usage: pyrowave-server [--port <PORT>] [--test] [--test-image <PATH>] [--test-video <PATH>]

        Default port: \(defaultPort) (UDP)

        Protocol: SPPW/1 (ScreenSpan PyroWire)
        Transport: UDP
        Video: 8-bit YCbCr 4:2:0 PyroWave v1
        Codec: upstream PyroWave Metal implementation
               (https://github.com/Themaister/pyrowave)

        Without --test the server captures the screen via ScreenCaptureKit,
        which requires the macOS screen recording permission.

        With --test the server streams generated content instead and never
        touches ScreenCaptureKit, so no permission is required:
          --test              animated broadcast test card
          --test-image PATH   a still image (PNG, JPEG, ...)
          --test-video PATH   a video file, played back in a loop
        """)
        exit(0)
    }
}

let port = requestedPort

// The test content mode decides what the server streams. It is deliberately
// separate from the screen capture path so that --test never triggers a
// Screen Recording permission prompt.
let testContentMode: TestContentMode?
if testVideoPath != nil {
    testContentMode = .video(URL(fileURLWithPath: testVideoPath!))
} else if testImagePath != nil {
    testContentMode = .image(URL(fileURLWithPath: testImagePath!))
} else if testMode {
    testContentMode = .card
} else {
    testContentMode = nil
}

if let testContentMode {
    print("Starting PyrowaveKit SPPW/1 server (TEST MODE) on UDP port \(port)...")
    switch testContentMode {
    case .card:
        print("Streaming an animated test card. No screen recording permission needed.")
    case .image(let url):
        print("Streaming the still image \(url.path). No screen recording permission needed.")
    case .video(let url):
        print("Streaming the video \(url.path). No screen recording permission needed.")
    }
} else {
    print("Starting PyrowaveKit SPPW/1 server on UDP port \(port)...")
    print("Note: Screen recording permission will be requested on first capture.")
}

let server = StreamServer(testContentMode: testContentMode)

Task {
    do {
        try await server.start(port: port)
    } catch {
        fputs("Failed to start server: \(error)\n", stderr)
        exit(1)
    }
}

dispatchMain()
