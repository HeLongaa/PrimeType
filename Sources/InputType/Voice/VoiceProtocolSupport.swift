import Foundation
import CommonCrypto
import CryptoKit
import Security
import os

// MARK: - Protocol Errors

enum VoiceProtocolError: LocalizedError {
    case invalidURL(String)
    case handshakeFailed(String)
    case networkFailed(String)
    case timeout(String)
    case protocolViolation(String)
    case cryptoFailed(String)
    case serverError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let msg),
             .handshakeFailed(let msg),
             .networkFailed(let msg),
             .timeout(let msg),
             .protocolViolation(let msg),
             .cryptoFailed(let msg),
             .serverError(let msg):
            return msg
        case .cancelled:
            return "语音识别已取消"
        }
    }
}

// MARK: - Protobuf Wire Codec

struct ProtoWriter {
    private(set) var data = Data()

    mutating func writeVarintRaw(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeVarint(field: UInt64, value: UInt64) {
        writeVarintRaw(field << 3)
        writeVarintRaw(value)
    }

    mutating func writeBytes(field: UInt64, value: Data) {
        writeVarintRaw((field << 3) | 2)
        writeVarintRaw(UInt64(value.count))
        data.append(value)
    }

    mutating func writeString(field: UInt64, value: String) {
        writeBytes(field: field, value: Data(value.utf8))
    }

    mutating func writeMessage(field: UInt64, value: ProtoWriter) {
        writeBytes(field: field, value: value.data)
    }

    mutating func writeKeyValue(field: UInt64, key: String, value: String) {
        var entry = ProtoWriter()
        entry.writeString(field: 1, value: key)
        entry.writeString(field: 2, value: value)
        writeMessage(field: field, value: entry)
    }
}

enum ProtoWireValue {
    case varint(UInt64)
    case bytes(Data)
    case fixed
}

struct ProtoMessage {
    let entries: [(field: UInt64, value: ProtoWireValue)]

    static func decode(_ data: Data) throws -> ProtoMessage {
        var items: [(UInt64, ProtoWireValue)] = []
        let bytes = [UInt8](data)
        var offset = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if shift >= 64 {
                    throw VoiceProtocolError.protocolViolation("Protobuf varint 溢出")
                }
                result |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return result
                }
                shift += 7
            }
            throw VoiceProtocolError.protocolViolation("Protobuf varint 截断")
        }

        while offset < bytes.count {
            let tag = try readVarint()
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                let v = try readVarint()
                items.append((fieldNumber, .varint(v)))
            case 1:
                guard offset + 8 <= bytes.count else {
                    throw VoiceProtocolError.protocolViolation("Protobuf fixed64 截断")
                }
                offset += 8
                items.append((fieldNumber, .fixed))
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, offset + length <= bytes.count else {
                    throw VoiceProtocolError.protocolViolation("Protobuf bytes 长度越界")
                }
                let slice = Data(bytes[offset..<(offset + length)])
                offset += length
                items.append((fieldNumber, .bytes(slice)))
            case 5:
                guard offset + 4 <= bytes.count else {
                    throw VoiceProtocolError.protocolViolation("Protobuf fixed32 截断")
                }
                offset += 4
                items.append((fieldNumber, .fixed))
            default:
                throw VoiceProtocolError.protocolViolation("不支持的 Protobuf wire type: \(wireType)")
            }
        }
        return ProtoMessage(entries: items)
    }

    func varint(for field: UInt64) -> UInt64? {
        for item in entries where item.field == field {
            if case .varint(let v) = item.value { return v }
        }
        return nil
    }

    func bytes(for field: UInt64) -> Data? {
        for item in entries where item.field == field {
            if case .bytes(let d) = item.value { return d }
        }
        return nil
    }

    func string(for field: UInt64) -> String? {
        bytes(for: field).map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - Crypto & Encoding Helpers (CryptoKit / CommonCrypto / Security)

enum VoiceCrypto {
    static func nowMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }

    static func hexString(_ data: Data, uppercase: Bool = false) -> String {
        let alphabet: [UInt8] = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0..<count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }

    static func randomHex(byteCount: Int, uppercase: Bool = false) -> String {
        hexString(randomBytes(count: byteCount), uppercase: uppercase)
    }

    static func randomLowerLetters(count: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var out = String()
        out.reserveCapacity(count)
        let bytes = randomBytes(count: count)
        for b in bytes {
            out.append(letters[Int(b) % letters.count])
        }
        return out
    }

    static func md5Hex(_ data: Data, uppercase: Bool = false) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return hexString(Data(digest), uppercase: uppercase)
    }

    static func sha256Hex(_ data: Data, uppercase: Bool = false) -> String {
        let digest = SHA256.hash(data: data)
        return hexString(Data(digest), uppercase: uppercase)
    }

    static func hmacSHA1Hex(key: Data, message: Data) -> String {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            message.withUnsafeBytes { msgPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress,
                    key.count,
                    msgPtr.baseAddress,
                    message.count,
                    &mac
                )
            }
        }
        return hexString(Data(mac), uppercase: false)
    }

    static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try commonCrypt(
            operation: CCOperation(kCCEncrypt),
            options: CCOptions(kCCOptionPKCS7Padding),
            key: key,
            iv: iv,
            input: plaintext
        )
    }

    static func aesECBEncrypt(key: Data, plaintext: Data) throws -> Data {
        try commonCrypt(
            operation: CCOperation(kCCEncrypt),
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            key: key,
            iv: nil,
            input: plaintext
        )
    }

    static func aesECBDecrypt(key: Data, ciphertext: Data) throws -> Data {
        try commonCrypt(
            operation: CCOperation(kCCDecrypt),
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            key: key,
            iv: nil,
            input: ciphertext
        )
    }

    private static func commonCrypt(
        operation: CCOperation,
        options: CCOptions,
        key: Data,
        iv: Data?,
        input: Data
    ) throws -> Data {
        let outCapacity = input.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var outMoved = 0

        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuf in
            input.withUnsafeBytes { inBuf in
                if let iv {
                    return iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress,
                            input.count,
                            &outBytes,
                            outCapacity,
                            &outMoved
                        )
                    }
                } else {
                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBuf.baseAddress,
                        key.count,
                        nil,
                        inBuf.baseAddress,
                        input.count,
                        &outBytes,
                        outCapacity,
                        &outMoved
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw VoiceProtocolError.cryptoFailed("AES 加解密失败 (CCCrypt status \(status))")
        }
        return Data(outBytes.prefix(outMoved))
    }

    /// Encrypts data using RSAES-OAEP with SHA-256 and an X.509 SPKI PEM public key.
    static func rsaOAEPSHA256Encrypt(spkiPEM: String, plaintext: Data) throws -> Data {
        let base64Body = spkiPEM
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let spkiDER = Data(base64Encoded: base64Body) else {
            throw VoiceProtocolError.cryptoFailed("RSA 公钥 Base64 解码失败")
        }
        let pkcs1DER = extractRSAPKCS1FromSPKI(spkiDER) ?? spkiDER

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var cfError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &cfError)
            ?? SecKeyCreateWithData(spkiDER as CFData, attributes as CFDictionary, &cfError) else {
            let reason = cfError?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw VoiceProtocolError.cryptoFailed("RSA 公钥加载失败：\(reason)")
        }

        var encError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionOAEPSHA256,
            plaintext as CFData,
            &encError
        ) as Data? else {
            let reason = encError?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw VoiceProtocolError.cryptoFailed("RSA-OAEP 加密失败：\(reason)")
        }
        return encrypted
    }

    /// Parses DER SubjectPublicKeyInfo (`SEQUENCE { AlgorithmIdentifier, BIT STRING }`) and returns the embedded PKCS#1 RSAPublicKey bytes.
    private static func extractRSAPKCS1FromSPKI(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var idx = 0

        func readTagAndLength() -> (tag: UInt8, length: Int)? {
            guard idx < bytes.count else { return nil }
            let tag = bytes[idx]
            idx += 1
            guard idx < bytes.count else { return nil }
            let firstLen = bytes[idx]
            idx += 1
            if firstLen < 0x80 {
                return (tag, Int(firstLen))
            }
            let count = Int(firstLen & 0x7F)
            guard count > 0, count <= 4, idx + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[idx])
                idx += 1
            }
            return (tag, length)
        }

        // Outer SEQUENCE
        guard let outer = readTagAndLength(), outer.tag == 0x30 else { return nil }
        // Skip AlgorithmIdentifier SEQUENCE
        guard let alg = readTagAndLength(), alg.tag == 0x30, idx + alg.length <= bytes.count else { return nil }
        idx += alg.length
        // BIT STRING containing unused-bits byte (0x00) + PKCS#1 RSAPublicKey SEQUENCE
        guard let bitStr = readTagAndLength(), bitStr.tag == 0x03, bitStr.length > 1, idx + bitStr.length <= bytes.count else {
            return nil
        }
        guard bytes[idx] == 0x00 else { return nil }
        return Data(bytes[(idx + 1)..<(idx + bitStr.length)])
    }

    static func rfc3986Encode(_ string: String) -> String {
        var out = String()
        out.reserveCapacity(string.utf8.count * 2)
        for b in string.utf8 {
            let isUnreserved =
                (b >= 0x41 && b <= 0x5A) || // A-Z
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E // - . _ ~
            if isUnreserved {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out.append(String(format: "%%%02X", b))
            }
        }
        return out
    }

    static func pcm16LittleEndianData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func joinSentenceFragments(_ parts: [String]) -> String {
        var combined = ""
        for part in parts where !part.isEmpty {
            if let prev = combined.last, let next = part.first, !isCJK(prev), !isCJK(next) {
                combined.append(" ")
            }
            combined.append(part)
        }
        return combined
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

// MARK: - Raw Snappy Block Format Codec

enum RawSnappy {
    /// Encodes bytes as a valid Raw Snappy block (uncompressed length varint + literal runs).
    static func compress(_ input: Data) -> Data {
        var out = Data()
        var remainingLen = UInt64(input.count)
        while remainingLen >= 0x80 {
            out.append(UInt8((remainingLen & 0x7F) | 0x80))
            remainingLen >>= 7
        }
        out.append(UInt8(remainingLen))

        let bytes = [UInt8](input)
        var offset = 0
        while offset < bytes.count {
            let chunkSize = min(60, bytes.count - offset)
            out.append(UInt8((chunkSize - 1) << 2))
            out.append(contentsOf: bytes[offset..<(offset + chunkSize)])
            offset += chunkSize
        }
        return out
    }

    /// Decodes a standard Raw Snappy block (literals + 1/2/4-byte copy tags).
    static func decompress(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        var idx = 0

        func readByte() throws -> Int {
            guard idx < bytes.count else {
                throw VoiceProtocolError.protocolViolation("Snappy 数据流截断")
            }
            let b = Int(bytes[idx])
            idx += 1
            return b
        }

        // Read uncompressed length varint
        var expectedLen = 0
        var shift = 0
        while true {
            let b = try readByte()
            if shift >= 63 {
                throw VoiceProtocolError.protocolViolation("Snappy 长度 varint 溢出")
            }
            expectedLen |= (b & 0x7F) << shift
            if (b & 0x80) == 0 { break }
            shift += 7
        }

        var output = [UInt8]()
        output.reserveCapacity(expectedLen)

        func copyMatch(backOffset: Int, length: Int) throws {
            guard backOffset > 0, backOffset <= output.count, output.count + length <= expectedLen else {
                throw VoiceProtocolError.protocolViolation("Snappy 回溯拷贝越界")
            }
            for _ in 0..<length {
                output.append(output[output.count - backOffset])
            }
        }

        while idx < bytes.count {
            let tag = try readByte()
            let tagType = tag & 0x03
            switch tagType {
            case 0: // Literal
                var litLen = tag >> 2
                if litLen >= 60 {
                    let extraBytes = litLen - 59
                    litLen = 0
                    for k in 0..<extraBytes {
                        litLen |= (try readByte()) << (8 * k)
                    }
                }
                litLen += 1
                guard idx + litLen <= bytes.count, output.count + litLen <= expectedLen else {
                    throw VoiceProtocolError.protocolViolation("Snappy 字面量长度越界")
                }
                output.append(contentsOf: bytes[idx..<(idx + litLen)])
                idx += litLen

            case 1: // Copy with 1-byte offset
                let length = ((tag >> 2) & 0x07) + 4
                let low = try readByte()
                let backOffset = ((tag >> 5) << 8) | low
                try copyMatch(backOffset: backOffset, length: length)

            case 2: // Copy with 2-byte offset
                let length = (tag >> 2) + 1
                let b0 = try readByte()
                let b1 = try readByte()
                let backOffset = b0 | (b1 << 8)
                try copyMatch(backOffset: backOffset, length: length)

            default: // Copy with 4-byte offset
                let length = (tag >> 2) + 1
                var backOffset = 0
                for k in 0..<4 {
                    backOffset |= (try readByte()) << (8 * k)
                }
                try copyMatch(backOffset: backOffset, length: length)
            }
        }

        guard output.count == expectedLen else {
            throw VoiceProtocolError.protocolViolation("Snappy 解压后长度不匹配 (\(output.count) != \(expectedLen))")
        }
        return Data(output)
    }
}

// MARK: - SECG secp128r1 Elliptic Curve Diffie-Hellman

enum Secp128r1ECDH {
    /// Unsigned 128-bit integer represented as `(hi, lo)` in big-endian word order.
    struct UInt128: Equatable, Comparable {
        var hi: UInt64
        var lo: UInt64

        static let zero = UInt128(hi: 0, lo: 0)
        static let one = UInt128(hi: 0, lo: 1)

        static func < (lhs: UInt128, rhs: UInt128) -> Bool {
            lhs.hi != rhs.hi ? lhs.hi < rhs.hi : lhs.lo < rhs.lo
        }

        func addingReportingOverflow(_ other: UInt128) -> (partialValue: UInt128, overflow: Bool) {
            let (loSum, loCarry) = lo.addingReportingOverflow(other.lo)
            let (hiSum1, hiCarry1) = hi.addingReportingOverflow(other.hi)
            let (hiSum2, hiCarry2) = hiSum1.addingReportingOverflow(loCarry ? 1 : 0)
            return (UInt128(hi: hiSum2, lo: loSum), hiCarry1 || hiCarry2)
        }

        func subtractingWrapping(_ other: UInt128) -> UInt128 {
            let (loDiff, borrow) = lo.subtractingReportingOverflow(other.lo)
            let hiDiff = hi &- other.hi &- (borrow ? 1 : 0)
            return UInt128(hi: hiDiff, lo: loDiff)
        }

        func shiftedRightOne() -> UInt128 {
            UInt128(hi: hi >> 1, lo: (lo >> 1) | ((hi & 1) << 63))
        }

        var isZero: Bool { hi == 0 && lo == 0 }
        var isOdd: Bool { (lo & 1) == 1 }

        var hexUpper32: String {
            String(format: "%016llX%016llX", hi, lo)
        }

        init(hi: UInt64, lo: UInt64) {
            self.hi = hi
            self.lo = lo
        }

        init?(hex32: String) {
            guard hex32.count == 32 else { return nil }
            let mid = hex32.index(hex32.startIndex, offsetBy: 16)
            guard let h = UInt64(hex32[..<mid], radix: 16),
                  let l = UInt64(hex32[mid...], radix: 16) else {
                return nil
            }
            self.hi = h
            self.lo = l
        }
    }

    struct Point: Equatable {
        let x: UInt128
        let y: UInt128
    }

    // SECG secp128r1 domain parameters
    // p = 2^128 - 2^97 - 1
    private static let fieldP = UInt128(hi: 0xFFFFFFFD_FFFFFFFF, lo: 0xFFFFFFFF_FFFFFFFF)
    private static let curveA = UInt128(hi: 0xFFFFFFFD_FFFFFFFF, lo: 0xFFFFFFFF_FFFFFFFC)
    private static let orderN = UInt128(hi: 0xFFFFFFFE_00000000, lo: 0x75A30D1B_9038A115)
    private static let generatorG = Point(
        x: UInt128(hi: 0x161FF752_8B899B2D, lo: 0x0C28607C_A52C5B86),
        y: UInt128(hi: 0xCF5AC839_5BAFEB13, lo: 0xC02DA292_DDED7A83)
    )
    // Since p = 2^128 - (2^97 + 1), 2^128 == 2^97 + 1 (mod p)
    private static let foldConstant = UInt128(hi: 1 << 33, lo: 1)

    /// Computes exact 256-bit product `(high128, low128)` of two 128-bit unsigned integers.
    private static func multiplyWide(_ a: UInt128, _ b: UInt128) -> (hi: UInt128, lo: UInt128) {
        let p00 = a.lo.multipliedFullWidth(by: b.lo)
        let p01 = a.lo.multipliedFullWidth(by: b.hi)
        let p10 = a.hi.multipliedFullWidth(by: b.lo)
        let p11 = a.hi.multipliedFullWidth(by: b.hi)

        let w0 = p00.low

        // Column 1: p00.high + p01.low + p10.low
        let (s1a, c1a) = p00.high.addingReportingOverflow(p01.low)
        let (w1, c1b) = s1a.addingReportingOverflow(p10.low)
        let carry1: UInt64 = (c1a ? 1 : 0) + (c1b ? 1 : 0)

        // Column 2: p11.low + p01.high + p10.high + carry1
        let (s2a, c2a) = p11.low.addingReportingOverflow(p01.high)
        let (s2b, c2b) = s2a.addingReportingOverflow(p10.high)
        let (w2, c2c) = s2b.addingReportingOverflow(carry1)
        let carry2: UInt64 = (c2a ? 1 : 0) + (c2b ? 1 : 0) + (c2c ? 1 : 0)

        // Column 3: p11.high + carry2
        let w3 = p11.high &+ carry2

        return (UInt128(hi: w3, lo: w2), UInt128(hi: w1, lo: w0))
    }

    private static func modAdd(_ a: UInt128, _ b: UInt128) -> UInt128 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow || sum >= fieldP {
            return sum.subtractingWrapping(fieldP)
        }
        return sum
    }

    private static func modSub(_ a: UInt128, _ b: UInt128) -> UInt128 {
        if a >= b {
            return a.subtractingWrapping(b)
        }
        let complement = fieldP.subtractingWrapping(b)
        return a.addingReportingOverflow(complement).partialValue
    }

    private static func modMul(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var (hi, lo) = multiplyWide(a, b)
        while !hi.isZero {
            let (h2, l2) = multiplyWide(hi, foldConstant)
            let (sumLo, carry) = lo.addingReportingOverflow(l2)
            lo = sumLo
            hi = carry ? h2.addingReportingOverflow(.one).partialValue : h2
        }
        while lo >= fieldP {
            lo = lo.subtractingWrapping(fieldP)
        }
        return lo
    }

    private static func modInv(_ x: UInt128) -> UInt128 {
        // Fermat's Little Theorem: x^(p-2) mod p
        var base = x >= fieldP ? x.subtractingWrapping(fieldP) : x
        var exp = fieldP.subtractingWrapping(UInt128(hi: 0, lo: 2))
        var result = UInt128.one
        while !exp.isZero {
            if exp.isOdd {
                result = modMul(result, base)
            }
            base = modMul(base, base)
            exp = exp.shiftedRightOne()
        }
        return result
    }

    private static func pointAdd(_ p1: Point?, _ p2: Point?) -> Point? {
        guard let p1 else { return p2 }
        guard let p2 else { return p1 }

        if p1.x == p2.x && modAdd(p1.y, p2.y).isZero {
            return nil // Point at infinity
        }

        let slope: UInt128
        if p1.x == p2.x && p1.y == p2.y {
            let xSq = modMul(p1.x, p1.x)
            let threeXSq = modAdd(modAdd(xSq, xSq), xSq)
            let num = modAdd(threeXSq, curveA)
            let den = modAdd(p1.y, p1.y)
            slope = modMul(num, modInv(den))
        } else {
            let num = modSub(p2.y, p1.y)
            let den = modSub(p2.x, p1.x)
            slope = modMul(num, modInv(den))
        }

        let x3 = modSub(modSub(modMul(slope, slope), p1.x), p2.x)
        let y3 = modSub(modMul(slope, modSub(p1.x, x3)), p1.y)
        return Point(x: x3, y: y3)
    }

    private static func scalarMul(_ scalar: UInt128, _ point: Point) -> Point? {
        var k = scalar
        var acc: Point? = nil
        var addend: Point? = point
        while !k.isZero {
            if k.isOdd {
                acc = pointAdd(acc, addend)
            }
            addend = pointAdd(addend, addend)
            k = k.shiftedRightOne()
        }
        return acc
    }

    static func generateKeyPair() -> (privateKey: UInt128, publicKeyHex: String) {
        while true {
            let raw = VoiceCrypto.randomBytes(count: 16)
            var hi: UInt64 = 0
            var lo: UInt64 = 0
            for i in 0..<8 { hi = (hi << 8) | UInt64(raw[i]) }
            for i in 8..<16 { lo = (lo << 8) | UInt64(raw[i]) }
            var candidate = UInt128(hi: hi, lo: lo)
            while candidate >= orderN {
                candidate = candidate.subtractingWrapping(orderN)
            }
            if candidate.isZero { continue }
            if let pub = scalarMul(candidate, generatorG) {
                return (candidate, "04" + pub.x.hexUpper32 + pub.y.hexUpper32)
            }
        }
    }

    /// Computes shared point X coordinate encoded as 32-char uppercase hex (used directly as 32-byte AES-256 key).
    static func deriveSharedKeyHex(privateKey: UInt128, peerPublicHex: String) throws -> String {
        guard peerPublicHex.count == 66, peerPublicHex.hasPrefix("04") else {
            throw VoiceProtocolError.cryptoFailed("secp128r1 对端公钥格式无效")
        }
        let xStart = peerPublicHex.index(peerPublicHex.startIndex, offsetBy: 2)
        let yStart = peerPublicHex.index(xStart, offsetBy: 32)
        guard let px = UInt128(hex32: String(peerPublicHex[xStart..<yStart])),
              let py = UInt128(hex32: String(peerPublicHex[yStart...])) else {
            throw VoiceProtocolError.cryptoFailed("secp128r1 对端公钥坐标解析失败")
        }
        guard let shared = scalarMul(privateKey, Point(x: px, y: py)) else {
            throw VoiceProtocolError.cryptoFailed("secp128r1 共享密钥计算失败")
        }
        return shared.x.hexUpper32
    }
}

// MARK: - Timeout Utility

func withAsyncTimeout<T: Sendable>(
    seconds: TimeInterval,
    message: String = "操作超时",
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let ns = UInt64(max(0.01, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            throw VoiceProtocolError.timeout(message)
        }
        guard let first = try await group.next() else {
            throw VoiceProtocolError.timeout(message)
        }
        group.cancelAll()
        return first
    }
}

// MARK: - Native URLSessionWebSocketTask Wrapper

final class VoiceWebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var isOpened = false
        var isClosed = false
        var openError: Error?
        var openContinuation: CheckedContinuation<Void, Error>?
    }

    private init(request: URLRequest, subprotocols: [String]) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpShouldUsePipelining = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 600
        let delegateBox = DelegateProxy()
        let session = URLSession(configuration: config, delegate: delegateBox, delegateQueue: nil)
        let task: URLSessionWebSocketTask
        if subprotocols.isEmpty {
            task = session.webSocketTask(with: request)
        } else {
            var mutableReq = request
            mutableReq.setValue(subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
            task = session.webSocketTask(with: mutableReq)
        }
        task.maximumMessageSize = 16 * 1024 * 1024
        self.session = session
        self.task = task
        super.init()
        delegateBox.owner = self
    }

    private final class DelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: VoiceWebSocket?

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            owner?.handleDidOpen()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            owner?.handleDidClose(error: VoiceProtocolError.networkFailed("服务端关闭了连接 (\(closeCode.rawValue))"))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                owner?.handleDidClose(error: error)
            }
        }
    }

    static func connect(
        url: URL,
        headers: [(String, String)] = [],
        subprotocols: [String] = [],
        timeout: TimeInterval = 10.0
    ) async throws -> VoiceWebSocket {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let ws = VoiceWebSocket(request: request, subprotocols: subprotocols)
        try await withTaskCancellationHandler {
            try await withAsyncTimeout(seconds: timeout, message: "连接服务器超时") {
                try await ws.awaitOpen()
            }
        } onCancel: {
            ws.close()
        }
        return ws
    }

    private func awaitOpen() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let immediate: Result<Void, Error>? = stateLock.withLock { s in
                if s.isOpened { return .success(()) }
                if let err = s.openError { return .failure(err) }
                if s.isClosed { return .failure(VoiceProtocolError.networkFailed("WebSocket 连接已关闭")) }
                s.openContinuation = cont
                return nil
            }
            if let immediate {
                cont.resume(with: immediate)
                return
            }
            task.resume()
        }
    }

    private func handleDidOpen() {
        let cont: CheckedContinuation<Void, Error>? = stateLock.withLock { s in
            s.isOpened = true
            let c = s.openContinuation
            s.openContinuation = nil
            return c
        }
        cont?.resume(returning: ())
    }

    private func handleDidClose(error: Error) {
        let cont: CheckedContinuation<Void, Error>? = stateLock.withLock { s in
            s.isClosed = true
            if s.openError == nil { s.openError = error }
            let c = s.openContinuation
            s.openContinuation = nil
            return c
        }
        cont?.resume(throwing: error)
        session.finishTasksAndInvalidate()
    }

    var isClosed: Bool {
        stateLock.withLock { $0.isClosed }
    }

    func sendBinary(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func receiveData() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return Data()
        }
    }

    func receiveData(timeout: TimeInterval) async throws -> Data {
        try await withAsyncTimeout(seconds: timeout, message: "服务器响应超时") {
            try await self.receiveData()
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        let cont: CheckedContinuation<Void, Error>? = stateLock.withLock { s in
            guard !s.isClosed else { return nil }
            s.isClosed = true
            let c = s.openContinuation
            s.openContinuation = nil
            return c
        }
        cont?.resume(throwing: VoiceProtocolError.cancelled)
        task.cancel(with: code, reason: nil)
        session.finishTasksAndInvalidate()
    }

    deinit {
        close()
    }
}

// MARK: - Reusable AsyncStream Session Adapter

/// Bridges synchronous `VoiceASRSession` calls (`push`/`finish`/`cancel`) into structured Swift concurrency,
/// guaranteeing callbacks are never delivered after cancellation or terminal completion.
final class StreamingVoiceASRSession: VoiceASRSession {
    private struct LifecycleState {
        var terminated = false
        var finishedInput = false
        var continuation: AsyncStream<[Int16]>.Continuation?
        var workerTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: LifecycleState())
    private let onEvent: (VoiceASREvent) -> Void

    init(
        onEvent: @escaping (VoiceASREvent) -> Void,
        runner: @escaping @Sendable (AsyncStream<[Int16]>, @escaping @Sendable (String) -> Void) async throws -> String
    ) {
        self.onEvent = onEvent

        var streamContinuation: AsyncStream<[Int16]>.Continuation?
        let stream = AsyncStream<[Int16]> { cont in
            streamContinuation = cont
        }

        state.withLock { s in
            s.continuation = streamContinuation
        }

        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let finalText = try await runner(stream) { [weak self] partial in
                    self?.emit(.partial(partial))
                }
                self.emitTerminal(.final(finalText))
            } catch is CancellationError {
                self.markTerminated()
            } catch VoiceProtocolError.cancelled {
                self.markTerminated()
            } catch {
                self.emitTerminal(.error(error.localizedDescription))
            }
        }

        state.withLock { s in
            if s.terminated {
                worker.cancel()
            } else {
                s.workerTask = worker
            }
        }
    }

    func push(pcm16: [Int16]) {
        guard !pcm16.isEmpty else { return }
        let cont = state.withLock { s -> AsyncStream<[Int16]>.Continuation? in
            guard !s.terminated, !s.finishedInput else { return nil }
            return s.continuation
        }
        cont?.yield(pcm16)
    }

    func finish() {
        let cont = state.withLock { s -> AsyncStream<[Int16]>.Continuation? in
            guard !s.terminated, !s.finishedInput else { return nil }
            s.finishedInput = true
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.finish()
    }

    func cancel() {
        let (cont, task) = state.withLock { s -> (AsyncStream<[Int16]>.Continuation?, Task<Void, Never>?) in
            s.terminated = true
            s.finishedInput = true
            let c = s.continuation
            let t = s.workerTask
            s.continuation = nil
            s.workerTask = nil
            return (c, t)
        }
        cont?.finish()
        task?.cancel()
    }

    private func emit(_ event: VoiceASREvent) {
        let allowed = state.withLock { !$0.terminated }
        guard allowed else { return }
        onEvent(event)
    }

    private func emitTerminal(_ event: VoiceASREvent) {
        let shouldEmit = state.withLock { s -> Bool in
            guard !s.terminated else { return false }
            s.terminated = true
            s.finishedInput = true
            s.continuation = nil
            s.workerTask = nil
            return true
        }
        guard shouldEmit else { return }
        onEvent(event)
    }

    private func markTerminated() {
        state.withLock { s in
            s.terminated = true
            s.finishedInput = true
            s.continuation = nil
            s.workerTask = nil
        }
    }

    deinit {
        cancel()
    }
}

// MARK: - Audio Leading Silence & Realtime Pacing Stream

enum VoiceAudioPacer {
    /// Prepends `leadingSilenceFrames` (default 10 frames = 200ms @ 20ms/frame) and paces output
    /// at no faster than 1 frame per `intervalMs` (default 20ms) to avoid bursting buffered frames.
    static func pacedStream(
        from source: AsyncStream<[Int16]>,
        leadingSilenceFrames: Int = 10,
        frameSamples: Int = 320,
        intervalMs: UInt64 = 20
    ) -> AsyncStream<[Int16]> {
        AsyncStream<[Int16]> { continuation in
            let task = Task {
                let intervalNs = intervalMs * 1_000_000
                var nextTick = DispatchTime.now().uptimeNanoseconds

                @Sendable func emitFrame(_ frame: [Int16]) async -> Bool {
                    if Task.isCancelled { return false }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if nextTick > now {
                        try? await Task.sleep(nanoseconds: nextTick - now)
                        if Task.isCancelled { return false }
                    } else {
                        nextTick = now
                    }
                    continuation.yield(frame)
                    nextTick &+= intervalNs
                    return true
                }

                let silence = [Int16](repeating: 0, count: frameSamples)
                for _ in 0..<leadingSilenceFrames {
                    if !(await emitFrame(silence)) {
                        continuation.finish()
                        return
                    }
                }
                for await frame in source {
                    if !(await emitFrame(frame)) {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
