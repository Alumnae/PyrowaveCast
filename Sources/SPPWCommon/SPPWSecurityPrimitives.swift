import CryptoKit
import Foundation

// MARK: - SPPW/1 security primitives
//
// Building blocks for the secure transport (see `SPPWSecurity.swift` and PROTOCOL.md §7):
// - `SPPWField25519` / `SPPWElligator2`: arithmetic modulo 2^255 − 19, used only to map a
//   hash to a Curve25519 point. All scalar multiplications go through CryptoKit's X25519.
// - `SPPWCPace`: a balanced PAKE in the style of CPace (draft-irtf-cfrg-cpace) on X25519,
//   so a 5-digit PIN or a password can authenticate a key exchange without giving an
//   attacker anything to guess offline: every guess needs one live exchange with the peer.
// - `SPPWReplayWindow`: sliding-window duplicate/replay filter for 64-bit packet counters.
//
// The field code is not constant time. It only runs on pairing (the PIN or password is
// hashed into the point before any of it runs), never on per-packet traffic.

/// Element of GF(2^255 − 19), always kept canonical (`0 ..< p`), four little-endian limbs.
struct SPPWField25519: Equatable, Sendable {
    fileprivate var limbs: [UInt64]

    static let p: [UInt64] = [0xFFFF_FFFF_FFFF_FFED, .max, .max, 0x7FFF_FFFF_FFFF_FFFF]
    static let zero = SPPWField25519(limbs: [0, 0, 0, 0])
    static let one = SPPWField25519(limbs: [1, 0, 0, 0])

    fileprivate init(limbs: [UInt64]) {
        self.limbs = limbs
    }

    init(_ small: UInt64) {
        self.limbs = [small, 0, 0, 0]
        reduceCanonical()
    }

    /// Little-endian 32 bytes; bit 255 is ignored (as for X25519 u-coordinates).
    init(littleEndian bytes: Data) {
        var limbs = [UInt64](repeating: 0, count: 4)
        let array = [UInt8](bytes.prefix(32)) + [UInt8](repeating: 0, count: max(0, 32 - bytes.count))
        for limb in 0..<4 {
            var value: UInt64 = 0
            for byte in (0..<8).reversed() {
                value = value << 8 | UInt64(array[limb * 8 + byte])
            }
            limbs[limb] = value
        }
        limbs[3] &= 0x7FFF_FFFF_FFFF_FFFF
        self.limbs = limbs
        reduceCanonical()
    }

    var littleEndianBytes: Data {
        var data = Data(capacity: 32)
        for limb in limbs {
            for shift in stride(from: 0, to: 64, by: 8) {
                data.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return data
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    private static func isAtLeastP(_ value: [UInt64]) -> Bool {
        for index in (0..<4).reversed() {
            if value[index] != p[index] { return value[index] > p[index] }
        }
        return true
    }

    /// 256-bit subtraction modulo 2^256; returns the borrow.
    @discardableResult
    private static func subtract(_ a: inout [UInt64], _ b: [UInt64]) -> Bool {
        var borrow = false
        for index in 0..<4 {
            let (d1, o1) = a[index].subtractingReportingOverflow(b[index])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            a[index] = d2
            borrow = o1 || o2
        }
        return borrow
    }

    /// 256-bit addition modulo 2^256; returns the carry.
    @discardableResult
    private static func add(_ a: inout [UInt64], _ b: [UInt64]) -> Bool {
        var carry = false
        for index in 0..<4 {
            let (s1, o1) = a[index].addingReportingOverflow(b[index])
            let (s2, o2) = s1.addingReportingOverflow(carry ? 1 : 0)
            a[index] = s2
            carry = o1 || o2
        }
        return carry
    }

    private mutating func reduceCanonical() {
        while Self.isAtLeastP(limbs) {
            Self.subtract(&limbs, Self.p)
        }
    }

    static func + (lhs: SPPWField25519, rhs: SPPWField25519) -> SPPWField25519 {
        var sum = lhs.limbs
        if add(&sum, rhs.limbs) {
            // 2^256 ≡ 38 (mod p); both inputs < p, so this cannot carry again.
            add(&sum, [38, 0, 0, 0])
        }
        var result = SPPWField25519(limbs: sum)
        result.reduceCanonical()
        return result
    }

    static func - (lhs: SPPWField25519, rhs: SPPWField25519) -> SPPWField25519 {
        var difference = lhs.limbs
        if subtract(&difference, rhs.limbs) {
            // Wrapped below zero: lhs − rhs + p is in range and exact modulo 2^256.
            add(&difference, p)
        }
        return SPPWField25519(limbs: difference)
    }

    static prefix func - (value: SPPWField25519) -> SPPWField25519 {
        zero - value
    }

    static func * (lhs: SPPWField25519, rhs: SPPWField25519) -> SPPWField25519 {
        // Schoolbook 4×4 limbs into 8.
        var wide = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = wide[i + j].addingReportingOverflow(low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                wide[i + j] = s2
                carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            wide[i + 4] = carry
        }
        // value = low + high · 2^256 ≡ low + 38 · high.
        var folded = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (high, low) = wide[index + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = wide[index].addingReportingOverflow(low)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            folded[index] = s2
            carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        folded[4] = carry
        // Fold the fifth limb (< 2^6) the same way.
        var result = Array(folded[0..<4])
        var extra = folded[4] &* 38
        while extra != 0 {
            if add(&result, [extra, 0, 0, 0]) {
                extra = 38
            } else {
                extra = 0
            }
        }
        var element = SPPWField25519(limbs: result)
        element.reduceCanonical()
        return element
    }

    func squared() -> SPPWField25519 { self * self }

    /// `self^exponent`, exponent as little-endian limbs.
    func power(_ exponent: [UInt64]) -> SPPWField25519 {
        var result = SPPWField25519.one
        var base = self
        for limb in exponent {
            var bits = limb
            for _ in 0..<64 {
                if bits & 1 == 1 { result = result * base }
                base = base.squared()
                bits >>= 1
            }
        }
        return result
    }

    /// Multiplicative inverse (`0` maps to `0`, like `inv0` in RFC 9380).
    func inverse() -> SPPWField25519 {
        power([0xFFFF_FFFF_FFFF_FFEB, .max, .max, 0x7FFF_FFFF_FFFF_FFFF])
    }

    /// Euler's criterion: `true` for zero and quadratic residues.
    var isSquare: Bool {
        let legendre = power([0xFFFF_FFFF_FFFF_FFF6, .max, .max, 0x3FFF_FFFF_FFFF_FFFF])
        return legendre == .one || legendre.isZero
    }
}

/// Elligator 2 map onto Curve25519 (`v² = u³ + A·u² + u`, A = 486662, Z = 2), returning the
/// u-coordinate of a point on the curve (never on the twist), as in RFC 9380 §6.7.1.
enum SPPWElligator2 {
    static let a = SPPWField25519(486_662)
    static let z = SPPWField25519(2)

    static func curveRightHandSide(_ u: SPPWField25519) -> SPPWField25519 {
        let u2 = u.squared()
        return u2 * u + a * u2 + u
    }

    static func map(_ r: SPPWField25519) -> SPPWField25519 {
        var x1 = -a * (SPPWField25519.one + z * r.squared()).inverse()
        if x1.isZero { x1 = -a }
        if curveRightHandSide(x1).isSquare {
            return x1
        }
        return -x1 - a
    }
}

// MARK: - CPace on X25519

public enum SPPWCPaceError: Error, Equatable {
    case invalidShare
    case degenerateResult
}

/// Balanced PAKE (CPace style) on X25519. Both parties derive the generator from the shared
/// low-entropy secret and a session identifier, exchange `y·G`, and get the same key only
/// when they used the same secret. An active attacker can test one secret per exchange;
/// a passive one learns nothing.
public enum SPPWCPace {
    static let domain = Data("SPPW/1 CPace X25519".utf8)

    /// Unicode NFKC, so the same password typed on different keyboards matches.
    public static func normalizedSecret(_ secret: String) -> Data {
        Data(secret.precomposedStringWithCompatibilityMapping.utf8)
    }

    /// The generator for `secret` and `sessionID` (u-coordinate, 32 bytes little-endian).
    public static func generator(secret: Data, sessionID: Data) -> Data {
        var hasher = SHA512()
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(domain))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(secret))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(sessionID))
        let digest = Data(hasher.finalize())
        let r = SPPWField25519(littleEndian: digest.prefix(32))
        return SPPWElligator2.map(r).littleEndianBytes
    }

    public struct Party: @unchecked Sendable {
        fileprivate let scalar: Curve25519.KeyAgreement.PrivateKey
        public let share: Data
    }

    /// Picks a fresh secret scalar and computes this side's share `y·G`.
    public static func start(secret: Data, sessionID: Data) throws -> Party {
        let scalar = Curve25519.KeyAgreement.PrivateKey()
        let share = try multiply(scalar, point: generator(secret: secret, sessionID: sessionID))
        return Party(scalar: scalar, share: share)
    }

    /// The intermediate session key; `initiatorShare`/`responderShare` fix the order.
    public static func finish(
        _ party: Party,
        peerShare: Data,
        sessionID: Data,
        initiatorShare: Data,
        responderShare: Data
    ) throws -> SymmetricKey {
        guard peerShare.count == 32 else { throw SPPWCPaceError.invalidShare }
        let k = try multiply(party.scalar, point: peerShare)
        var hasher = SHA512()
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(Data("SPPW/1 CPace ISK".utf8)))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(sessionID))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(k))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(initiatorShare))
        hasher.update(data: SPPWSecureEncoding.lengthPrefixed(responderShare))
        return SymmetricKey(data: Data(hasher.finalize()))
    }

    private static func multiply(_ scalar: Curve25519.KeyAgreement.PrivateKey, point: Data) throws -> Data {
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: point)
        } catch {
            throw SPPWCPaceError.invalidShare
        }
        let shared: SharedSecret
        do {
            shared = try scalar.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw SPPWCPaceError.degenerateResult
        }
        let bytes = shared.withUnsafeBytes { Data($0) }
        // A low-order point gives the all-zero result: never accept it.
        guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else {
            throw SPPWCPaceError.degenerateResult
        }
        return bytes
    }
}

// MARK: - Replay window

/// Accepts each 64-bit counter at most once, within a window of the 1024 most recent.
/// Counters start at 1; reordering inside the window (Wi-Fi bursts) is fine.
public struct SPPWReplayWindow: Sendable {
    public static let size: UInt64 = 1024
    private var slots = [UInt64](repeating: 0, count: Int(SPPWReplayWindow.size))
    public private(set) var highest: UInt64 = 0

    public init() {}

    /// `true` if `counter` was never seen and is not older than the window.
    public func wouldAccept(_ counter: UInt64) -> Bool {
        guard counter > 0 else { return false }
        if counter + Self.size <= highest { return false }
        return slots[Int(counter % Self.size)] != counter
    }

    /// Records `counter` (call after the packet authenticated); returns whether it was new.
    @discardableResult
    public mutating func accept(_ counter: UInt64) -> Bool {
        guard wouldAccept(counter) else { return false }
        slots[Int(counter % Self.size)] = counter
        highest = max(highest, counter)
        return true
    }
}

// MARK: - Encoding helpers

enum SPPWSecureEncoding {
    static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        appendU32(UInt32(data.count), to: &out)
        out.append(data)
        return out
    }

    static func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    static func appendU32(_ value: UInt32, to data: inout Data) {
        appendU16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        appendU16(UInt16(truncatingIfNeeded: value), to: &data)
    }

    static func appendU64(_ value: UInt64, to data: inout Data) {
        appendU32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
        appendU32(UInt32(truncatingIfNeeded: value), to: &data)
    }

    static func u64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = value << 8 | UInt64(bytes[index])
        }
        return value
    }

    /// Short UTF-8 string field: `UInt8 length` + bytes (at most 64).
    static func appendShortString(_ string: String, to data: inout Data) {
        var bytes = Data(string.utf8.prefix(64))
        while String(data: bytes, encoding: .utf8) == nil, !bytes.isEmpty { bytes.removeLast() }
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }

    /// Reads a short string at `offset`, advancing it; `nil` if truncated.
    static func readShortString(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        let length = Int(bytes[offset])
        guard offset + 1 + length <= bytes.count else { return nil }
        let string = String(decoding: bytes[(offset + 1)..<(offset + 1 + length)], as: UTF8.self)
        offset += 1 + length
        return string
    }
}
