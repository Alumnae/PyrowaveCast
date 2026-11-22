import Foundation

// The iOS app target compiles PyrowaveKit sources directly instead of through
// SwiftPM, so its Metal resource bundle is the main application bundle.
extension Bundle {
    static var module: Bundle { .main }
}
