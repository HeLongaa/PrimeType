import Foundation

enum OpusEncoderError: LocalizedError {
    case createFailed(Int32)
    case controlFailed(Int32)
    case encodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .createFailed(let code):
            return "Opus 编码器创建失败 (code \(code))"
        case .controlFailed(let code):
            return "Opus 编码器参数设置失败 (code \(code))"
        case .encodeFailed(let code):
            return "Opus 音频编码失败 (code \(code))"
        }
    }
}

/// Thin Swift wrapper around Xiph.Org libopus (BSD-3-Clause).
final class OpusEncoder {
    enum Application: Int32 {
        case voip = 2048
        case audio = 2049
    }

    private let encoder: OpaquePointer
    private var outputBuffer: [UInt8]

    init(
        sampleRate: Int32 = 16000,
        channels: Int32 = 1,
        application: Application,
        bitrate: Int32,
        complexity: Int32
    ) throws {
        var err: Int32 = 0
        guard let ptr = opus_encoder_create(sampleRate, channels, application.rawValue, &err), err == OPUS_OK else {
            throw OpusEncoderError.createFailed(err)
        }
        let brStatus = primetype_opus_encoder_set_bitrate(ptr, bitrate)
        if brStatus != OPUS_OK {
            opus_encoder_destroy(ptr)
            throw OpusEncoderError.controlFailed(brStatus)
        }
        let cxStatus = primetype_opus_encoder_set_complexity(ptr, complexity)
        if cxStatus != OPUS_OK {
            opus_encoder_destroy(ptr)
            throw OpusEncoderError.controlFailed(cxStatus)
        }
        self.encoder = ptr
        self.outputBuffer = [UInt8](repeating: 0, count: 4000)
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    func encode(pcm16: [Int16]) throws -> Data {
        guard !pcm16.isEmpty else { return Data() }
        let encodedBytes: Int32 = pcm16.withUnsafeBufferPointer { inBuf in
            outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                guard let inBase = inBuf.baseAddress, let outBase = outBuf.baseAddress else {
                    return -1
                }
                return opus_encode(
                    encoder,
                    inBase,
                    Int32(inBuf.count),
                    outBase,
                    Int32(outBuf.count)
                )
            }
        }
        guard encodedBytes > 0 else {
            throw OpusEncoderError.encodeFailed(encodedBytes)
        }
        return Data(outputBuffer.prefix(Int(encodedBytes)))
    }
}
