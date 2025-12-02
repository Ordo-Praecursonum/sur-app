//
//  Bech32.swift
//  Sur
//
//  Bech32 encoding implementation for Cosmos addresses
//  Reference: BIP-173 (https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki)
//

import Foundation

/// Bech32 encoding for Cosmos addresses
struct Bech32 {
    
    /// Bech32 character set
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    
    /// Bech32 generator values for checksum
    private static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    
    /// Encode data with Bech32
    /// - Parameters:
    ///   - hrp: Human-readable part (e.g., "cosmos")
    ///   - data: Data to encode (20 bytes for Cosmos addresses)
    /// - Returns: Bech32-encoded string
    static func encode(hrp: String, data: Data) -> String? {
        // Convert 8-bit data to 5-bit groups
        guard let fiveBitData = convertBits(data: [UInt8](data), fromBits: 8, toBits: 5, pad: true) else {
            return nil
        }
        
        // Create checksum
        let checksum = createChecksum(hrp: hrp, data: fiveBitData)
        
        // Combine data and checksum
        let combined = fiveBitData + checksum
        
        // Encode to Bech32 string
        var result = hrp + "1"
        for value in combined {
            guard value < 32 else { return nil }
            let index = charset.index(charset.startIndex, offsetBy: Int(value))
            result.append(charset[index])
        }
        
        return result
    }
    
    /// Decode a Bech32 string
    /// - Parameter string: Bech32-encoded string
    /// - Returns: Tuple of (hrp, data) or nil if invalid
    static func decode(_ string: String) -> (hrp: String, data: Data)? {
        // Find separator
        guard let separatorIndex = string.lastIndex(of: "1") else {
            return nil
        }
        
        // Extract HRP and data
        let hrp = String(string[..<separatorIndex])
        let dataString = String(string[string.index(after: separatorIndex)...])
        
        // Decode characters
        var decoded = [UInt8]()
        for char in dataString.lowercased() {
            guard let index = charset.firstIndex(of: char) else {
                return nil
            }
            decoded.append(UInt8(charset.distance(from: charset.startIndex, to: index)))
        }
        
        // Verify checksum
        guard verifyChecksum(hrp: hrp, data: decoded) else {
            return nil
        }
        
        // Remove checksum (last 6 characters)
        let dataWithoutChecksum = Array(decoded.dropLast(6))
        
        // Convert from 5-bit to 8-bit
        guard let eightBitData = convertBits(data: dataWithoutChecksum, fromBits: 5, toBits: 8, pad: false) else {
            return nil
        }
        
        return (hrp, Data(eightBitData))
    }
    
    // MARK: - Private Helpers
    
    /// Convert bits between different bit widths
    private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc: Int = 0
        var bits: Int = 0
        var result = [UInt8]()
        let maxv: Int = (1 << toBits) - 1
        
        for value in data {
            if Int(value) >> fromBits != 0 {
                return nil
            }
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        
        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            return nil
        }
        
        return result
    }
    
    /// Create Bech32 checksum
    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = expandHrp(hrp) + data + [0, 0, 0, 0, 0, 0]
        let polymod = polymod(values) ^ 1
        var checksum = [UInt8]()
        for i in 0..<6 {
            checksum.append(UInt8((polymod >> (5 * (5 - i))) & 31))
        }
        return checksum
    }
    
    /// Verify Bech32 checksum
    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        let values = expandHrp(hrp) + data
        return polymod(values) == 1
    }
    
    /// Expand HRP for checksum calculation
    private static func expandHrp(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp {
            guard let asciiValue = char.asciiValue else {
                // Non-ASCII character, skip or handle error
                continue
            }
            result.append(UInt8(asciiValue >> 5))
        }
        result.append(0)
        for char in hrp {
            guard let asciiValue = char.asciiValue else {
                // Non-ASCII character, skip or handle error
                continue
            }
            result.append(UInt8(asciiValue & 31))
        }
        return result
    }
    
    /// Compute Bech32 polymod for checksum
    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(value)
            for i in 0..<5 {
                if (top >> i) & 1 != 0 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }
}
