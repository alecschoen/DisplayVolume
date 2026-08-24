import CoreAudio
import Foundation

/// Format inspection and validation for the streams handled by the pipeline.
/// The pipeline supports stereo linear PCM Float32, interleaved or
/// non-interleaved, at whatever sample rate the device exposes
/// (44.1 kHz / 48 kHz / 96 kHz are the common cases).
public enum AudioFormatUtilities {

    public struct ValidatedFormat: Equatable {
        public let sampleRate: Double
        public let channelCount: Int
        public let isInterleaved: Bool

        public init(sampleRate: Double, channelCount: Int, isInterleaved: Bool) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.isInterleaved = isInterleaved
        }
    }

    public static func isFloat32LinearPCM(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && asbd.mBitsPerChannel == 32
    }

    public static func isInterleaved(_ asbd: AudioStreamBasicDescription) -> Bool {
        (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    }

    /// Validates that a format is something the real-time path can handle.
    public static func validate(_ asbd: AudioStreamBasicDescription) throws -> ValidatedFormat {
        guard isFloat32LinearPCM(asbd) else {
            throw DisplayVolumeError.unsupportedFormat(details: describe(asbd))
        }
        guard asbd.mChannelsPerFrame >= 1 else {
            throw DisplayVolumeError.unsupportedFormat(details: "zero channels: " + describe(asbd))
        }
        return ValidatedFormat(sampleRate: asbd.mSampleRate,
                               channelCount: Int(asbd.mChannelsPerFrame),
                               isInterleaved: isInterleaved(asbd))
    }

    public static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let formatName: String
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM: formatName = "LinearPCM"
        default:
            formatName = fourCharString(asbd.mFormatID)
        }
        let float = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int"
        let inter = isInterleaved(asbd) ? "interleaved" : "non-interleaved"
        return String(format: "%@ %.0f Hz, %u ch, %u-bit %@, %@",
                      formatName, asbd.mSampleRate, asbd.mChannelsPerFrame,
                      asbd.mBitsPerChannel, float, inter)
    }

    static func fourCharString(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return String(value)
    }
}
