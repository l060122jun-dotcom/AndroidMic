// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Android/Rust messages.proto: bytes buffer=1; uint32 sample_rate=2;
// uint32 channel_count=3; uint32 audio_format=4. No protobuf dependency needed.
enum AudioPacketEncoder {
    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remainder = value
        while remainder >= 128 {
            data.append(UInt8(remainder & 127) | 128)
            remainder >>= 7
        }
        data.append(UInt8(remainder))
    }

    static func frame(pcm: Data, sampleRate: UInt32) -> Data {
        var payload = Data()
        payload.append(0x0A)
        appendVarint(UInt64(pcm.count), to: &payload)
        payload.append(pcm)
        payload.append(0x10)
        appendVarint(UInt64(sampleRate), to: &payload)
        payload.append(contentsOf: [0x18, 0x01, 0x20, 0x02])
        let count = UInt32(payload.count)
        var result = Data([
            UInt8(truncatingIfNeeded: count >> 24),
            UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8),
            UInt8(truncatingIfNeeded: count)
        ])
        result.append(payload)
        return result
    }
}
