import Foundation

struct StreamStatus: Sendable, Equatable {
    var isRunning = false
    var port: UInt16 = 0
    var connectedClients = 0
    var framesSent = 0
    var bytesSent = 0
    var megabitsPerSecond = 0.0
    var width = 0
    var height = 0
    var fps = 0
    var mode = ""
    var videoCurrentTimeSeconds = 0.0
    var videoDurationSeconds = 0.0
}

struct ServerLogEntry: Sendable, Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    let text: String
    let isError: Bool
}
