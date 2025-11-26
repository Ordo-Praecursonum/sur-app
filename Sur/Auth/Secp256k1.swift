//
//  Secp256k1.swift
//  Sur
//
//  Pure Swift implementation of secp256k1 elliptic curve operations.
//  This curve is used by Ethereum, Bitcoin, and other cryptocurrencies for key generation.
//
//  IMPORTANT: This implementation provides:
//  - Private key to public key derivation
//  - Proper uncompressed public key format (65 bytes: 0x04 + X + Y)
//  - Compatibility with MetaMask and other Ethereum wallets
//
//  The secp256k1 curve parameters:
//  - p (prime): 2^256 - 2^32 - 977
//  - a = 0
//  - b = 7
//  - G = generator point
//  - n = order of G (curve order)
//

import Foundation

/// secp256k1 elliptic curve implementation for Ethereum compatibility
final class Secp256k1 {
    
    // MARK: - Curve Parameters
    
    /// The prime field p = 2^256 - 2^32 - 977
    static let p = BigUInt(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")!
    
    /// Curve order n (order of the generator point G)
    static let n = BigUInt(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
    
    /// Curve coefficient a = 0
    static let a = BigUInt.zero
    
    /// Curve coefficient b = 7
    static let b = BigUInt(7)
    
    /// Generator point G (x-coordinate)
    static let gx = BigUInt(hexString: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!
    
    /// Generator point G (y-coordinate)
    static let gy = BigUInt(hexString: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")!
    
    // MARK: - Point Structure
    
    /// Represents a point on the secp256k1 curve
    struct Point: Equatable {
        let x: BigUInt
        let y: BigUInt
        let isInfinity: Bool
        
        /// Point at infinity (identity element)
        static let infinity = Point(x: .zero, y: .zero, isInfinity: true)
        
        /// Generator point G
        static let generator = Point(x: gx, y: gy, isInfinity: false)
        
        init(x: BigUInt, y: BigUInt, isInfinity: Bool = false) {
            self.x = x
            self.y = y
            self.isInfinity = isInfinity
        }
    }
    
    // MARK: - Public Interface
    
    /// Derive public key from private key
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: 65-byte uncompressed public key (0x04 + X + Y) or nil if invalid
    static func derivePublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        
        // Convert private key to BigUInt
        let scalar = BigUInt(data: privateKey)
        
        // Validate private key is in valid range [1, n-1]
        guard scalar > .zero && scalar < n else { return nil }
        
        // Compute public key = scalar * G
        let publicPoint = scalarMultiply(scalar: scalar, point: .generator)
        
        guard !publicPoint.isInfinity else { return nil }
        
        // Format as uncompressed public key (0x04 + X + Y)
        var result = Data([0x04])
        result.append(publicPoint.x.toData(length: 32))
        result.append(publicPoint.y.toData(length: 32))
        
        return result
    }
    
    /// Derive compressed public key from private key
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: 33-byte compressed public key (0x02/0x03 + X) or nil if invalid
    static func deriveCompressedPublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        
        let scalar = BigUInt(data: privateKey)
        guard scalar > .zero && scalar < n else { return nil }
        
        let publicPoint = scalarMultiply(scalar: scalar, point: .generator)
        guard !publicPoint.isInfinity else { return nil }
        
        // Compressed format: 0x02 for even y, 0x03 for odd y
        let prefix: UInt8 = publicPoint.y.isEven ? 0x02 : 0x03
        var result = Data([prefix])
        result.append(publicPoint.x.toData(length: 32))
        
        return result
    }
    
    /// Validate private key is in valid range
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: true if valid
    static func isValidPrivateKey(_ privateKey: Data) -> Bool {
        guard privateKey.count == 32 else { return false }
        
        let scalar = BigUInt(data: privateKey)
        return scalar > .zero && scalar < n
    }
    
    // MARK: - Elliptic Curve Operations
    
    /// Add two points on the curve
    static func pointAdd(_ p1: Point, _ p2: Point) -> Point {
        if p1.isInfinity { return p2 }
        if p2.isInfinity { return p1 }
        
        // If points are inverses, return infinity
        if p1.x == p2.x && (p1.y + p2.y) % p == .zero {
            return .infinity
        }
        
        let lambda: BigUInt
        
        if p1.x == p2.x && p1.y == p2.y {
            // Point doubling: λ = (3x₁² + a) / (2y₁)
            let numerator = (BigUInt(3) * p1.x * p1.x + a) % p
            let denominator = (BigUInt(2) * p1.y) % p
            lambda = (numerator * modInverse(denominator, p)) % p
        } else {
            // Point addition: λ = (y₂ - y₁) / (x₂ - x₁)
            let numerator = (p2.y + p - p1.y) % p
            let denominator = (p2.x + p - p1.x) % p
            lambda = (numerator * modInverse(denominator, p)) % p
        }
        
        // x₃ = λ² - x₁ - x₂
        let x3 = (lambda * lambda + p + p - p1.x - p2.x) % p
        
        // y₃ = λ(x₁ - x₃) - y₁
        let y3 = (lambda * ((p1.x + p - x3) % p) + p - p1.y) % p
        
        return Point(x: x3, y: y3)
    }
    
    /// Double-and-add scalar multiplication
    static func scalarMultiply(scalar: BigUInt, point: Point) -> Point {
        var result = Point.infinity
        var current = point
        var k = scalar
        
        while k > .zero {
            if k.isOdd {
                result = pointAdd(result, current)
            }
            current = pointAdd(current, current) // Point doubling
            k = k >> 1
        }
        
        return result
    }
    
    /// Compute modular multiplicative inverse using extended Euclidean algorithm
    static func modInverse(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        if a == .zero {
            return .zero
        }
        
        var (old_r, r) = (a, m)
        var (old_s, s) = (BigUInt.one, BigUInt.zero)
        var isNegative = false
        
        while r != .zero {
            let quotient = old_r / r
            let temp_r = r
            
            // Handle subtraction with potential negative results
            if old_r >= quotient * r {
                r = old_r - quotient * r
            } else {
                r = quotient * r - old_r
            }
            old_r = temp_r
            
            let temp_s = s
            let product = quotient * s
            
            if !isNegative {
                if old_s >= product {
                    s = old_s - product
                    isNegative = false
                } else {
                    s = product - old_s
                    isNegative = true
                }
            } else {
                s = old_s + product
                isNegative = false
            }
            old_s = temp_s
        }
        
        // Ensure result is positive
        if isNegative {
            return m - (old_s % m)
        }
        return old_s % m
    }
}

// MARK: - BigUInt Implementation

/// Simple big unsigned integer for secp256k1 operations
/// Stores 256-bit numbers as an array of 64-bit words (little-endian)
struct BigUInt: Equatable, Comparable {
    private var words: [UInt64]
    
    /// Zero value
    static let zero = BigUInt()
    
    /// One value
    static let one = BigUInt(1)
    
    init() {
        self.words = [0, 0, 0, 0]
    }
    
    init(_ value: UInt64) {
        self.words = [value, 0, 0, 0]
    }
    
    init(words: [UInt64]) {
        self.words = words
        while self.words.count < 4 {
            self.words.append(0)
        }
    }
    
    /// Initialize from hex string
    init?(hexString: String) {
        var hex = hexString.lowercased()
        if hex.hasPrefix("0x") {
            hex = String(hex.dropFirst(2))
        }
        
        // Pad to 64 characters (256 bits)
        while hex.count < 64 {
            hex = "0" + hex
        }
        
        var words = [UInt64]()
        
        // Parse 16 hex characters at a time (64 bits) from right to left
        var index = hex.endIndex
        while words.count < 4 && index > hex.startIndex {
            let start = hex.index(index, offsetBy: -min(16, hex.distance(from: hex.startIndex, to: index)))
            let chunk = String(hex[start..<index])
            guard let value = UInt64(chunk, radix: 16) else { return nil }
            words.append(value)
            index = start
        }
        
        while words.count < 4 {
            words.append(0)
        }
        
        self.words = words
    }
    
    /// Initialize from Data (big-endian)
    init(data: Data) {
        var words = [UInt64](repeating: 0, count: 4)
        let bytes = [UInt8](data)
        
        // Convert big-endian bytes to little-endian words
        for (i, byte) in bytes.enumerated() {
            let wordIndex = (bytes.count - 1 - i) / 8
            let byteIndex = (bytes.count - 1 - i) % 8
            if wordIndex < 4 {
                words[wordIndex] |= UInt64(byte) << (byteIndex * 8)
            }
        }
        
        self.words = words
    }
    
    /// Convert to Data (big-endian, padded to specified length)
    func toData(length: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        
        for wordIndex in 0..<4 {
            for byteIndex in 0..<8 {
                let globalByteIndex = length - 1 - (wordIndex * 8 + byteIndex)
                if globalByteIndex >= 0 && globalByteIndex < length {
                    bytes[globalByteIndex] = UInt8((words[wordIndex] >> (byteIndex * 8)) & 0xFF)
                }
            }
        }
        
        return Data(bytes)
    }
    
    /// Convert to hex string
    func toHexString() -> String {
        var result = ""
        for word in words.reversed() {
            result += String(format: "%016llx", word)
        }
        return result.drop(while: { $0 == "0" }).isEmpty ? "0" : String(result.drop(while: { $0 == "0" }))
    }
    
    var isOdd: Bool {
        return words[0] & 1 == 1
    }
    
    var isEven: Bool {
        return words[0] & 1 == 0
    }
    
    /// Check if value is zero
    var isZero: Bool {
        return words.allSatisfy { $0 == 0 }
    }
    
    // MARK: - Arithmetic Operations
    
    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        
        for i in 0..<4 {
            let sum = lhs.words[i].addingReportingOverflow(rhs.words[i])
            let sumWithCarry = sum.partialValue.addingReportingOverflow(carry)
            result[i] = sumWithCarry.partialValue
            carry = (sum.overflow ? 1 : 0) + (sumWithCarry.overflow ? 1 : 0)
        }
        result[4] = carry
        
        return BigUInt(words: Array(result.prefix(4)))
    }
    
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        
        for i in 0..<4 {
            let diff = lhs.words[i].subtractingReportingOverflow(rhs.words[i])
            let diffWithBorrow = diff.partialValue.subtractingReportingOverflow(borrow)
            result[i] = diffWithBorrow.partialValue
            borrow = (diff.overflow ? 1 : 0) + (diffWithBorrow.overflow ? 1 : 0)
        }
        
        return BigUInt(words: result)
    }
    
    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: 8)
        
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                if i + j < 8 {
                    let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                    let sum1 = result[i + j].addingReportingOverflow(low)
                    let sum2 = sum1.partialValue.addingReportingOverflow(carry)
                    result[i + j] = sum2.partialValue
                    carry = high + (sum1.overflow ? 1 : 0) + (sum2.overflow ? 1 : 0)
                }
            }
            if i + 4 < 8 {
                result[i + 4] = result[i + 4].addingReportingOverflow(carry).partialValue
            }
        }
        
        // Truncate to 256 bits
        return BigUInt(words: Array(result.prefix(4)))
    }
    
    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if rhs.isZero { return .zero }
        if lhs < rhs { return .zero }
        if lhs == rhs { return .one }
        
        var quotient = BigUInt.zero
        var remainder = BigUInt.zero
        
        // Process each bit from MSB to LSB
        for wordIndex in (0..<4).reversed() {
            for bitIndex in (0..<64).reversed() {
                // Shift remainder left by 1 and add next bit
                remainder = remainder << 1
                let bit = (lhs.words[wordIndex] >> bitIndex) & 1
                remainder.words[0] |= bit
                
                if remainder >= rhs {
                    remainder = remainder - rhs
                    let qWordIndex = wordIndex
                    quotient.words[qWordIndex] |= (1 << bitIndex)
                }
            }
        }
        
        return quotient
    }
    
    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if rhs.isZero { return lhs }
        if lhs < rhs { return lhs }
        if lhs == rhs { return .zero }
        
        var remainder = BigUInt.zero
        
        // Process each bit from MSB to LSB
        for wordIndex in (0..<4).reversed() {
            for bitIndex in (0..<64).reversed() {
                // Shift remainder left by 1 and add next bit
                remainder = remainder << 1
                let bit = (lhs.words[wordIndex] >> bitIndex) & 1
                remainder.words[0] |= bit
                
                if remainder >= rhs {
                    remainder = remainder - rhs
                }
            }
        }
        
        return remainder
    }
    
    static func << (lhs: BigUInt, rhs: Int) -> BigUInt {
        guard rhs > 0 else { return lhs }
        guard rhs < 256 else { return .zero }
        
        let wordShift = rhs / 64
        let bitShift = rhs % 64
        
        var result = [UInt64](repeating: 0, count: 4)
        
        for i in 0..<4 {
            if i + wordShift < 4 {
                result[i + wordShift] |= lhs.words[i] << bitShift
            }
            if bitShift > 0 && i + wordShift + 1 < 4 {
                result[i + wordShift + 1] |= lhs.words[i] >> (64 - bitShift)
            }
        }
        
        return BigUInt(words: result)
    }
    
    static func >> (lhs: BigUInt, rhs: Int) -> BigUInt {
        guard rhs > 0 else { return lhs }
        guard rhs < 256 else { return .zero }
        
        let wordShift = rhs / 64
        let bitShift = rhs % 64
        
        var result = [UInt64](repeating: 0, count: 4)
        
        for i in 0..<4 {
            if i >= wordShift {
                result[i - wordShift] |= lhs.words[i] >> bitShift
            }
            if bitShift > 0 && i > wordShift {
                result[i - wordShift - 1] |= lhs.words[i] << (64 - bitShift)
            }
        }
        
        return BigUInt(words: result)
    }
    
    // MARK: - Comparison
    
    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        for i in (0..<4).reversed() {
            if lhs.words[i] < rhs.words[i] { return true }
            if lhs.words[i] > rhs.words[i] { return false }
        }
        return false
    }
    
    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return rhs < lhs
    }
    
    static func <= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return !(lhs > rhs)
    }
    
    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return !(lhs < rhs)
    }
}
