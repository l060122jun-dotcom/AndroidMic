import Foundation

let packet = AudioPacketEncoder.frame(pcm: Data([0x00, 0x80, 0xFF, 0x7F]), sampleRate: 48000)
let expected: [UInt8] = [
    0, 0, 0, 14,
    0x0A, 4, 0x00, 0x80, 0xFF, 0x7F,
    0x10, 0x80, 0xF7, 0x02,
    0x18, 1, 0x20, 2
]
precondition(Array(packet) == expected, "Protobuf field encoding or big-endian framing mismatch")
let largePCM = Data(repeating: 0x5A, count: 960)
let largePacket = AudioPacketEncoder.frame(pcm: largePCM, sampleRate: 44100)
let length = largePacket.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
precondition(Int(length) == largePacket.count - 4)
precondition(Array(largePacket[4..<7]) == [0x0A, 0xC0, 0x07])
print("PASS: AndroidMic protobuf and TCP framing fixtures")
