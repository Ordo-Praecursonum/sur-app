//
//  AppAttestManager+CBOR.swift
//  Sur
//
//  CBOR decoding of Apple App Attest attestation objects.
//  Extracts authData, attStmt, and x5c certificate chain from the
//  CBOR-encoded attestation object returned by DCAppAttestService.
//
//  The attestation object format follows the WebAuthn attestation format:
//  https://www.w3.org/TR/webauthn/#attestation-object
//

import Foundation

// MARK: - Attestation Object Parsing

/// Parsed Apple App Attest attestation object
public struct AppAttestAttestation {
    /// The authenticator data (authData)
    public let authData: Data
    
    /// The attestation statement format (e.g., "apple-appattest")
    public let fmt: String
    
    /// The x5c certificate chain from the attestation statement
    public let x5cChain: [Data]
    
    /// The receipt from the attestation statement
    public let receipt: Data?
}

/// Parsed authenticator data from the attestation object
public struct AuthenticatorData {
    /// SHA-256 hash of the relying party ID (32 bytes)
    public let rpIdHash: Data
    
    /// Flags byte
    public let flags: UInt8
    
    /// Signature counter (4 bytes, big-endian)
    public let signCount: UInt32
    
    /// Attested credential data (if present)
    public let attestedCredentialData: AttestedCredentialData?
    
    /// Whether user is present (bit 0)
    public var isUserPresent: Bool { flags & 0x01 != 0 }
    
    /// Whether attested credential data is included (bit 6)
    public var hasAttestedCredentialData: Bool { flags & 0x40 != 0 }
}

/// Attested credential data from authenticator data
public struct AttestedCredentialData {
    /// AAGUID (16 bytes) — identifies the authenticator model
    /// Note: This should NOT be included in MsgAddDevice (privacy — reveals device model family)
    public let aaguid: Data
    
    /// Credential ID length (2 bytes, big-endian)
    public let credentialIdLength: UInt16
    
    /// Credential ID
    public let credentialId: Data
    
    /// Credential public key (COSE-encoded)
    public let credentialPublicKey: Data
}

// MARK: - CBOR Decoding

extension AppAttestManager {
    
    /// Decode an Apple App Attest attestation object from CBOR bytes.
    ///
    /// The attestation object is a CBOR map with keys:
    /// - "fmt": string (attestation statement format)
    /// - "attStmt": map (attestation statement)
    /// - "authData": bytes (authenticator data)
    ///
    /// - Parameter data: Raw CBOR-encoded attestation object bytes
    /// - Returns: Parsed AppAttestAttestation
    public static func decodeAttestationObject(_ data: Data) throws -> AppAttestAttestation {
        var offset = 0
        let bytes = [UInt8](data)
        
        guard !bytes.isEmpty else {
            throw AppAttestError.cborDecodingFailed("Empty attestation object")
        }
        
        // Parse CBOR map
        guard let map = try parseCBORMap(bytes: bytes, offset: &offset) else {
            throw AppAttestError.cborDecodingFailed("Expected CBOR map at root")
        }
        
        // Extract "fmt"
        guard let fmtValue = map["fmt"],
              case .text(let fmt) = fmtValue else {
            throw AppAttestError.cborDecodingFailed("Missing or invalid 'fmt' field")
        }
        
        // Extract "authData"
        guard let authDataValue = map["authData"],
              case .bytes(let authData) = authDataValue else {
            throw AppAttestError.cborDecodingFailed("Missing or invalid 'authData' field")
        }
        
        // Extract "attStmt"
        guard let attStmtValue = map["attStmt"],
              case .map(let attStmt) = attStmtValue else {
            throw AppAttestError.cborDecodingFailed("Missing or invalid 'attStmt' field")
        }
        
        // Extract x5c certificate chain from attStmt
        var x5cChain: [Data] = []
        if let x5cValue = attStmt["x5c"],
           case .array(let x5cArray) = x5cValue {
            for item in x5cArray {
                if case .bytes(let certData) = item {
                    x5cChain.append(certData)
                }
            }
        }
        
        // Extract receipt from attStmt
        var receipt: Data? = nil
        if let receiptValue = attStmt["receipt"],
           case .bytes(let receiptData) = receiptValue {
            receipt = receiptData
        }
        
        return AppAttestAttestation(
            authData: authData,
            fmt: fmt,
            x5cChain: x5cChain,
            receipt: receipt
        )
    }
    
    /// Parse the authenticator data from raw bytes.
    ///
    /// Format:
    /// - rpIdHash: 32 bytes
    /// - flags: 1 byte
    /// - signCount: 4 bytes (big-endian)
    /// - attestedCredentialData: variable (if flags bit 6 is set)
    public static func parseAuthenticatorData(_ data: Data) throws -> AuthenticatorData {
        let bytes = [UInt8](data)
        
        guard bytes.count >= 37 else {
            throw AppAttestError.cborDecodingFailed("AuthenticatorData too short: \(bytes.count) bytes")
        }
        
        let rpIdHash = Data(bytes[0..<32])
        let flags = bytes[32]
        let signCount = UInt32(bytes[33]) << 24 | UInt32(bytes[34]) << 16 |
                        UInt32(bytes[35]) << 8 | UInt32(bytes[36])
        
        var attestedCredentialData: AttestedCredentialData? = nil
        
        // Check if attested credential data is present (bit 6)
        if flags & 0x40 != 0 && bytes.count > 37 {
            var offset = 37
            
            // AAGUID: 16 bytes
            guard offset + 16 <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("AuthenticatorData: AAGUID truncated")
            }
            let aaguid = Data(bytes[offset..<offset+16])
            offset += 16
            
            // Credential ID length: 2 bytes big-endian
            guard offset + 2 <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("AuthenticatorData: credentialIdLength truncated")
            }
            let credIdLen = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            offset += 2
            
            // Credential ID
            guard offset + Int(credIdLen) <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("AuthenticatorData: credentialId truncated")
            }
            let credentialId = Data(bytes[offset..<offset + Int(credIdLen)])
            offset += Int(credIdLen)
            
            // Credential public key: remaining bytes (COSE-encoded)
            let credentialPublicKey = Data(bytes[offset...])
            
            attestedCredentialData = AttestedCredentialData(
                aaguid: aaguid,
                credentialIdLength: credIdLen,
                credentialId: credentialId,
                credentialPublicKey: credentialPublicKey
            )
        }
        
        return AuthenticatorData(
            rpIdHash: rpIdHash,
            flags: flags,
            signCount: signCount,
            attestedCredentialData: attestedCredentialData
        )
    }
    
    // MARK: - CBOR Primitive Types
    
    /// Represents a CBOR value
    enum CBORValue {
        case uint(UInt64)
        case negint(Int64)
        case bytes(Data)
        case text(String)
        case array([CBORValue])
        case map([String: CBORValue])
        case bool(Bool)
        case null
        case float(Double)
    }
    
    /// Parse a CBOR value from bytes
    static func parseCBORValue(bytes: [UInt8], offset: inout Int) throws -> CBORValue {
        guard offset < bytes.count else {
            throw AppAttestError.cborDecodingFailed("Unexpected end of CBOR data")
        }
        
        let initial = bytes[offset]
        let majorType = initial >> 5
        let additionalInfo = initial & 0x1f
        offset += 1
        
        switch majorType {
        case 0: // Unsigned integer
            let value = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            return .uint(value)
            
        case 1: // Negative integer
            let value = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            return .negint(-1 - Int64(value))
            
        case 2: // Byte string
            let length = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            guard offset + Int(length) <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("Byte string truncated")
            }
            let data = Data(bytes[offset..<offset + Int(length)])
            offset += Int(length)
            return .bytes(data)
            
        case 3: // Text string
            let length = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            guard offset + Int(length) <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("Text string truncated")
            }
            let data = Data(bytes[offset..<offset + Int(length)])
            offset += Int(length)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AppAttestError.cborDecodingFailed("Invalid UTF-8 in text string")
            }
            return .text(text)
            
        case 4: // Array
            let count = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            var items: [CBORValue] = []
            for _ in 0..<count {
                let item = try parseCBORValue(bytes: bytes, offset: &offset)
                items.append(item)
            }
            return .array(items)
            
        case 5: // Map
            let count = try readUInt(bytes: bytes, additionalInfo: additionalInfo, offset: &offset)
            var dict: [String: CBORValue] = [:]
            for _ in 0..<count {
                let key = try parseCBORValue(bytes: bytes, offset: &offset)
                let value = try parseCBORValue(bytes: bytes, offset: &offset)
                if case .text(let keyStr) = key {
                    dict[keyStr] = value
                }
            }
            return .map(dict)
            
        case 7: // Simple values and floats
            switch additionalInfo {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 25: // Half-precision float
                guard offset + 2 <= bytes.count else {
                    throw AppAttestError.cborDecodingFailed("Float16 truncated")
                }
                offset += 2
                return .float(0) // Simplified — half-precision not commonly used
            case 26: // Single-precision float
                guard offset + 4 <= bytes.count else {
                    throw AppAttestError.cborDecodingFailed("Float32 truncated")
                }
                let bits = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset+1]) << 16 |
                           UInt32(bytes[offset+2]) << 8 | UInt32(bytes[offset+3])
                offset += 4
                return .float(Double(Float(bitPattern: bits)))
            case 27: // Double-precision float
                guard offset + 8 <= bytes.count else {
                    throw AppAttestError.cborDecodingFailed("Float64 truncated")
                }
                var bits: UInt64 = 0
                for i in 0..<8 {
                    bits |= UInt64(bytes[offset + i]) << (56 - i * 8)
                }
                offset += 8
                return .float(Double(bitPattern: bits))
            default:
                return .null
            }
            
        default:
            throw AppAttestError.cborDecodingFailed("Unknown CBOR major type: \(majorType)")
        }
    }
    
    /// Parse a CBOR map from bytes
    static func parseCBORMap(bytes: [UInt8], offset: inout Int) throws -> [String: CBORValue]? {
        let value = try parseCBORValue(bytes: bytes, offset: &offset)
        if case .map(let dict) = value {
            return dict
        }
        return nil
    }
    
    /// Read an unsigned integer from CBOR additional info
    private static func readUInt(bytes: [UInt8], additionalInfo: UInt8, offset: inout Int) throws -> UInt64 {
        if additionalInfo < 24 {
            return UInt64(additionalInfo)
        }
        
        switch additionalInfo {
        case 24:
            guard offset < bytes.count else {
                throw AppAttestError.cborDecodingFailed("UInt8 truncated")
            }
            let value = UInt64(bytes[offset])
            offset += 1
            return value
        case 25:
            guard offset + 2 <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("UInt16 truncated")
            }
            let value = UInt64(bytes[offset]) << 8 | UInt64(bytes[offset + 1])
            offset += 2
            return value
        case 26:
            guard offset + 4 <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("UInt32 truncated")
            }
            let value = UInt64(bytes[offset]) << 24 | UInt64(bytes[offset + 1]) << 16 |
                        UInt64(bytes[offset + 2]) << 8 | UInt64(bytes[offset + 3])
            offset += 4
            return value
        case 27:
            guard offset + 8 <= bytes.count else {
                throw AppAttestError.cborDecodingFailed("UInt64 truncated")
            }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(bytes[offset + i]) << (56 - i * 8)
            }
            offset += 8
            return value
        default:
            throw AppAttestError.cborDecodingFailed("Invalid additional info for integer: \(additionalInfo)")
        }
    }
}
