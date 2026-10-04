// SPDX-License-Identifier: GPL-3.0-only
// Compatible with AndroidMic's TCP handshake and AudioPacketMessage protocol.
import AVFoundation
import Foundation
import Network

final class MicrophoneStreamer: ObservableObject {
    @Published var isRunning = false
    @Published var status = "尚未连接"
    private let queue = DispatchQueue(label: "AndroidMic.stream")
    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var pendingPackets = 0
    private let sendSlots = DispatchSemaphore(value: 3)
    private var attempt: UUID?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.stop()
        }
    }

    deinit {
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        connection?.cancel()
        engine?.stop()
    }

    // UI methods are called on the main thread; transport state lives on queue.
    func start(host: String, port: String) {
        guard !isRunning else { return }
        guard !host.isEmpty, let number = UInt16(port), number > 0,
              let endpointPort = NWEndpoint.Port(rawValue: number) else {
            status = "请输入电脑地址和有效端口（1–65535）"
            return
        }
        let id = UUID()
        attempt = id
        isRunning = true
        status = "等待麦克风授权…"
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.attempt == id else { return }
                guard allowed else {
                    self.isRunning = false
                    self.status = "麦克风权限被拒绝，请在系统设置中允许"
                    return
                }
                self.status = "正在连接电脑…"
                self.queue.async { self.connect(host: host, port: endpointPort) }
            }
        }
    }

    func stop() {
        attempt = nil
        isRunning = false
        status = "已停止"
        queue.async { self.shutdown() }
    }

    private func connect(host: String, port: NWEndpoint.Port) {
        shutdown()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let client = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        connection = client
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self = self, let client = client, self.connection === client else { return }
            switch state {
            case .ready:
                client.send(content: Data("AndroidMic1".utf8), completion: .contentProcessed { error in
                    guard self.connection === client else { return }
                    if let error = error { self.fail(error.localizedDescription); return }
                    self.readHandshake(client: client, accumulated: Data())
                })
            case .failed(let error): self.fail(error.localizedDescription)
            case .waiting(let error): self.publish("等待网络：\(error.localizedDescription)")
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self = self, let client = client,
                  self.connection === client, self.engine == nil else { return }
            self.fail("连接或握手超时，请检查电脑端模式、端口和防火墙")
        }
    }

    private func readHandshake(client: NWConnection, accumulated: Data) {
        let expected = Data("AndroidMic2".utf8)
        client.receive(minimumIncompleteLength: 1, maximumLength: expected.count - accumulated.count) {
            [weak self] data, _, complete, error in
            guard let self = self, self.connection === client else { return }
            if let error = error { self.fail(error.localizedDescription); return }
            var received = accumulated
            if let data = data { received.append(data) }
            if received.count == expected.count {
                guard received == expected else { self.fail("握手不匹配，请使用兼容的 AndroidMic 电脑端"); return }
                do {
                    try self.beginCapture(client: client)
                    self.watchDisconnect(client: client)
                } catch { self.fail(error.localizedDescription) }
            } else if complete {
                self.fail("电脑在握手时断开了连接")
            } else {
                self.readHandshake(client: client, accumulated: received)
            }
        }
    }

    private func beginCapture(client: NWConnection) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48000)
        // Preference only: actual hardware duration is reported after activation.
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        let audioEngine = AVAudioEngine()
        engine = audioEngine
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "AndroidMic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前麦克风音频格式不可用"])
        }
        let sampleRate = UInt32(format.sampleRate.rounded())
        // Sink receives the hardware render quantum. A tap's requested bufferSize
        // is not a reliable low-latency guarantee on iOS.
        let sink = AVAudioSinkNode { [weak self, weak client] _, frameCount, audioBufferList in
            guard let self = self, let client = client else { return noErr }
            // Reserve before dispatching: even queue backlog cannot grow unbounded.
            guard self.sendSlots.wait(timeout: .now()) == .success else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard let first = buffers.first, let source = first.mData else {
                self.sendSlots.signal()
                return noErr
            }
            let floats = source.assumingMemoryBound(to: Float.self)
            let stride = Int(first.mNumberChannels)
            var pcm = Data(count: Int(frameCount) * 2)
            pcm.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                for index in 0..<Int(frameCount) {
                    let raw = floats[index * stride]
                    let value = raw.isFinite ? max(-1, min(1, raw)) : 0
                    let bits = UInt16(bitPattern: Int16((value * 32767).rounded()))
                    destination[index * 2] = UInt8(truncatingIfNeeded: bits)
                    destination[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
            let packet = AudioPacketEncoder.frame(pcm: pcm, sampleRate: sampleRate)
            self.queue.async {
                guard self.connection === client else { self.sendSlots.signal(); return }
                self.pendingPackets += 1
                client.send(content: packet, completion: .contentProcessed { [weak self] error in
                    self?.sendSlots.signal()
                    guard let self = self, self.connection === client else { return }
                    self.pendingPackets -= 1
                    if let error = error { self.fail(error.localizedDescription) }
                })
            }
            return noErr
        }
        audioEngine.attach(sink)
        audioEngine.connect(input, to: sink, format: format)
        audioEngine.prepare()
        try audioEngine.start()
        let duration = String(format: "%.1f", session.ioBufferDuration * 1000)
        let inputLatency = String(format: "%.1f", session.inputLatency * 1000)
        publish("正在传输 · \(sampleRate) Hz · 单声道 · 16 位\n硬件缓冲 \(duration) ms · 系统报告输入延迟 \(inputLatency) ms（非端到端实测）")
    }

    private func watchDisconnect(client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self = self, self.connection === client else { return }
            if let error = error { self.fail(error.localizedDescription) }
            else if complete { self.fail("电脑已断开，请重新连接") }
            else { self.watchDisconnect(client: client) }
        }
    }

    private func shutdown() {
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
        engine?.stop()
        engine = nil
        pendingPackets = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        shutdown()
        DispatchQueue.main.async { self.isRunning = false; self.status = "失败：\(message)" }
    }

    private func publish(_ message: String) {
        DispatchQueue.main.async { self.status = message }
    }
}
