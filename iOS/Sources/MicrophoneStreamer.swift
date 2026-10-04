// SPDX-License-Identifier: GPL-3.0-only
// Compatible with AndroidMic's TCP handshake and AudioPacketMessage protocol.
//
// Low-latency capture path (see README.zh-CN.md for the honest limitations):
//   AVAudioSinkNode render block  ->  bounded convert into a preallocated
//   scratch buffer  ->  AMRing_write (SPSC, allocation-free, no locks).
// A dedicated high-priority consumer thread polls the ring (~1 ms), builds the
// protobuf packet and calls NWConnection.send, keeping at most 3 sends in
// flight. The render block never allocates, never locks, never dispatches and
// never touches Network.framework.
import AVFoundation
import Foundation
import Network

final class MicrophoneStreamer: ObservableObject {
    @Published var isRunning = false
    @Published var status = "尚未连接"

    private let queue = DispatchQueue(label: "AndroidMic.stream")
    private let sendQueue = DispatchQueue(label: "AndroidMic.send", qos: .userInitiated)
    private let sendQueueKey = DispatchSpecificKey<Bool>()

    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var attempt: UUID?
    private var transportAttempt: UUID?
    private var interruptionObserver: NSObjectProtocol?
    private var connectionTimeout: DispatchWorkItem?
    private var consumerTimer: DispatchSourceTimer?

    // SPSC ring handed from the render thread to the send thread. Created on
    // `queue` before the engine starts; destroyed only after the engine stops.
    private var ring: OpaquePointer?  // AMRing *
    private var consumerRunning = false

    // Consumer-side drop counters, mutated only on `sendQueue`.
    private var consumerDiscards: UInt64 = 0
    private var congestionDrops: UInt64 = 0
    private var sentBlocks: UInt64 = 0
    private var lastStatsReport = DispatchTime.now()

    // Render-thread-owned scratch: exactly one AMAudioBufferList's worth is not
    // knowable ahead of time, so we allocate a generous fixed ceiling once.
    // 8192 frames * 2 bytes = 16 KiB covers every iOS hardware quantum.
    private static let maxFramesPerBlock = 8192
    private var scratch: UnsafeMutablePointer<UInt8>?
    private let scratchCapacity = maxFramesPerBlock * 2 + 2 // PCM16 and block header

    // Capacity is burst slack; consumer separately discards stale whole blocks.
    // At 48 kHz mono PCM16 one second is 96 KiB, so 32 KiB is ~341 ms of audio:
    // enough to absorb a multi-hundred-millisecond consumer stall without the
    // producer dropping blocks. Raising it further only buys a longer stall
    // before loss; shrinking it trades stall tolerance for latency after a stall.
    private static let ringCapacityBytes = 32 * 1024

    // Backlog above which the consumer starts discarding stale audio instead of
    // transmitting it. 400 ms at 48 kHz (~76.8 KiB) is *larger* than the ring
    // (32 KiB), so under normal load the discard branch can never trigger: the
    // producer would have to drop blocks first for the ring to fill. Discarding
    // therefore only fires if the ring were ever enlarged. The old threshold was
    // 20 ms, which is below one I/O cycle + one TCP write, so ordinary jitter
    // could cross it and cut audio continuously.
    private static let backlogDiscard_bytesPerSecond = 2 // PCM16 mono: 2 bytes/frame
    private static let backlogDiscard_milliseconds = 400

    // Render-thread-owned drop counters (written only by the audio thread via
    // `enqueueRealtime`, read by the UI thread as a snapshot). They are plain
    // integers, not atomics, because the render thread is their only writer;
    // tearing on a 64-bit aligned read is not observable on Apple arm64/x86_64.
    private var producerDrops: UInt64 = 0
    private var droppedFrames: UInt64 = 0

    // Connection-level backpressure: at most 3 unacknowledged sends in flight.
    // Reserved on `sendQueue`, released from NW completions, so it is guarded
    // by `slotLock` (never touched on the render thread).
    private var inFlight = 0
    private static let maxInFlight = 3

    private let pollInterval: DispatchTimeInterval = .milliseconds(1)

    init() {
        sendQueue.setSpecific(key: sendQueueKey, value: true)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            switch type {
            case .began:
                self?.stop(reason: "系统中断，已停止；中断结束后请重新连接")
            case .ended:
                // Do not silently resume: the session may need explicit
                // reactivation and the user may be on a call. Surface it.
                self?.publish("麦克风中断已结束，可重新连接")
            @unknown default:
                break
            }
        }
    }

    deinit {
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        // Best-effort teardown that mirrors shutdown() but without touching
        // @Published (illegal-ish during deinit). Must stop the consumer and
        // engine before freeing the ring/scratch.
        consumerTimer?.cancel()
        consumerTimer = nil
        if DispatchQueue.getSpecific(key: sendQueueKey) == true {
            consumerRunning = false
        } else {
            sendQueue.sync { consumerRunning = false }
        }
        let connection = self.connection
        let engine = self.engine
        let ring = self.ring
        let scratch = self.scratch
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        engine?.stop()
        if let ring = ring { AMRing_destroy(ring) }
        if let scratch = scratch { scratch.deallocate() }
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
        requestPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.attempt == id else { return }
                guard allowed else {
                    self.isRunning = false
                    self.status = "麦克风权限被拒绝，请在系统设置中允许"
                    return
                }
                self.status = "正在连接电脑…"
                self.queue.async { self.connect(host: host, port: endpointPort, id: id) }
            }
        }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    func stop() {
        stop(reason: "已停止")
    }

    private func stop(reason: String) {
        attempt = nil
        isRunning = false
        status = reason
        queue.async { self.shutdown() }
    }

    private func connect(host: String, port: NWEndpoint.Port, id: UUID) {
        shutdown()
        transportAttempt = id
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
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
            case .waiting(let error):
                self.publish("等待网络/本地网络权限：\(error.localizedDescription)")
            default: break
            }
        }
        client.start(queue: queue)
        scheduleConnectionTimeout(client: client, seconds: 10)
    }

    private func scheduleConnectionTimeout(client: NWConnection, seconds: Double) {
        connectionTimeout?.cancel()
        let item = DispatchWorkItem { [weak self, weak client] in
            guard let self = self, let client = client,
                  self.connection === client, self.engine == nil else { return }
            self.fail("连接或握手超时，请检查电脑端模式、端口、防火墙，以及手机的本地网络权限")
        }
        connectionTimeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
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
        connectionTimeout?.cancel()
        connectionTimeout = nil

        let session = AVAudioSession.sharedInstance()
        // `.measurement` disables the system's AGC, noise suppression and other
        // "voice processing"-style DSP so we transmit what the microphone
        // actually captured, which is what preserves quality for the PC side's
        // own processing. The default `.voiceChat`/`.spokenAudio` modes would
        // apply gain control and can pump or gate quiet passages. `.record`
        // category with `.measurement` is the recording-appropriate pair here.
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48000)
        // Preference only: actual hardware duration is reported after activation.
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        // Allocate scratch + ring before the engine starts. From here on the
        // render thread may touch them, so nothing below may fail.
        if scratch == nil {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchCapacity)
            buffer.initialize(repeating: 0, count: scratchCapacity)
            scratch = buffer
        }
        if ring == nil {
            guard let created = AMRing_create(MicrophoneStreamer.ringCapacityBytes) else {
                throw NSError(domain: "AndroidMic", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建音频环形缓冲"])
            }
            ring = created
        }

        let audioEngine = AVAudioEngine()
        engine = audioEngine
        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              hardwareFormat.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "AndroidMic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前麦克风音频格式不可用"])
        }
        // The render block reads the sink's buffer layout, so connecting the sink
        // with an explicit mono format asks AVAudioEngine to do the hardware
        // channel downmix in its converter, using the platform's proper matrix
        // (which does not phase-cancel a correlated pair). We only reach the
        // in-block averaging fallback above if that mono format could not be
        // created. Reporting mono is therefore honest, not an assumption.
        let captureFormat: AVAudioFormat
        if hardwareFormat.channelCount == 1 {
            captureFormat = hardwareFormat
        } else if let mono = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1) {
            captureFormat = mono
        } else {
            captureFormat = hardwareFormat
        }
        // The declared sample rate is exactly the format the sink was connected
        // with, and AVAudioSinkNode renders at that rate, so the frame rate the
        // receiver sees matches this header. We never request a different rate
        // and never resample on device; if the hardware could not satisfy 48 kHz
        // this reports whatever rate it actually runs at, so there is no silent
        // mismatch between the reported rate and the emitted frames.
        let sampleRate = UInt32(captureFormat.sampleRate.rounded())
        guard sampleRate > 0 else {
            throw NSError(domain: "AndroidMic", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "采样率无效"])
        }

        let sink = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            // Realtime-safe: read into our own scratch, enqueue, return.
            self.enqueueRealtime(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        audioEngine.attach(sink)
        audioEngine.connect(input, to: sink, format: captureFormat)
        audioEngine.prepare()
        // Reset drop counters before the render thread can run, so the producer
        // never races a reset of its own counters.
        producerDrops = 0
        droppedFrames = 0
        consumerDiscards = 0
        congestionDrops = 0
        sentBlocks = 0
        lastStatsReport = DispatchTime.now()
        try audioEngine.start()

        startConsumer(client: client, sampleRate: sampleRate)

        let duration = String(format: "%.1f", session.ioBufferDuration * 1000)
        let inputLatency = String(format: "%.1f", session.inputLatency * 1000)
        let ringNote = AMRing_is_lock_free(ring) ? "" : "（环形缓冲非原子无锁，性能可能下降）"
        publish("正在传输 · \(sampleRate) Hz · 单声道 · 16 位\n硬件缓冲 \(duration) ms · 系统报告输入延迟 \(inputLatency) ms（非端到端实测）\(ringNote)")
    }

    // MARK: - Realtime producer (Core Audio render thread)

    // Runs on the audio render thread. MUST NOT allocate, lock, dispatch or
    // touch Network.framework. It only converts bounded frames into the
    // preallocated scratch buffer and copies whole framed blocks into the SPSC
    // ring. If the ring cannot hold a whole block, the block is dropped here
    // (bounded loss) rather than blocking the render thread or splitting a
    // frame across writes.
    private func enqueueRealtime(audioBufferList: UnsafePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
        guard let ring = ring, let scratch = scratch else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard let first = buffers.first, let source = first.mData else { return }

        let frames = min(Int(frameCount), MicrophoneStreamer.maxFramesPerBlock)
        guard frames > 0 else { return }
        let channelStride = max(Int(first.mNumberChannels), 1)
        let channelCount = buffers.count > 1 ? buffers.count : channelStride
        let floats = source.assumingMemoryBound(to: Float.self)
        let byteCount = frames * 2
        let headerSize = 2
        let blockSize = byteCount + headerSize
        guard blockSize <= scratchCapacity else { return }
        // Whole-block atomicity: never split a frame across two writes.
        guard AMRing_free_space(ring) >= blockSize else {
            // Bounded loss: the whole block is dropped, never partially written.
            producerDrops &+= 1
            droppedFrames &+= UInt64(frames)
            return
        }

        scratch[0] = UInt8(truncatingIfNeeded: frames)
        scratch[1] = UInt8(truncatingIfNeeded: frames >> 8)

        var destination = scratch + headerSize
        if channelStride == 1 && buffers.count == 1 {
            // Fast path: already mono, no mixing needed.
            for index in 0..<frames {
                let bits = Self.pcm16(from: floats[index])
                destination[0] = UInt8(truncatingIfNeeded: bits)
                destination[1] = UInt8(truncatingIfNeeded: bits >> 8)
                destination += 2
            }
        } else {
            // Interleaved or multi-buffer: collapse to mono. Plain averaging can
            // phase-cancel a correlated-but-inverted pair (e.g. a mic array or a
            // wired source with swapped polarity) and silently produce silence.
            // We compare the averaged energy against the loudest single channel
            // and fall back to that channel when averaging cancels too much.
            for index in 0..<frames {
                var best: Float = 0
                var bestMagnitude: Float = 0
                var correlation: Float = 0
                var energy0: Float = 0
                var energy1: Float = 0
                var sum: Float = 0
                var firstValid: Float = 0
                var secondValid: Float = 0
                var validCount = 0
                for channel in 0..<channelCount {
                    let raw: Float
                    if buffers.count > 1 {
                        guard let channelData = buffers[channel].mData else { continue }
                        raw = channelData.assumingMemoryBound(to: Float.self)[index]
                    } else {
                        raw = floats[index * channelStride + channel]
                    }
                    let sample = raw.isFinite ? raw : 0
                    if channel == 0 { firstValid = sample }
                    if channel == 1 { secondValid = sample }
                    let magnitude = abs(sample)
                    if magnitude > bestMagnitude {
                        bestMagnitude = magnitude
                        best = sample
                    }
                    energy0 += firstValid * firstValid
                    energy1 += secondValid * secondValid
                    correlation += firstValid * secondValid
                    sum += sample
                    validCount += 1
                }
                let candidate: Float
                if validCount > 0 {
                    let averaged = sum / Float(validCount)
                    // Negative correlation with near-equal energy is the
                    // phase-cancellation signature. Near-equal energy keeps this
                    // cheap and allocation-free; a true mic array would need a
                    // better selection metric, but iOS normally hands us a mono
                    // format already (see captureFormat in beginCapture).
                    let dominated = correlation < 0 && energy0 > 0 && energy1 > 0
                        && min(energy0, energy1) > 0.5 * max(energy0, energy1)
                    candidate = dominated ? best : averaged
                } else {
                    candidate = best
                }
                let bits = Self.pcm16(from: candidate)
                destination[0] = UInt8(truncatingIfNeeded: bits)
                destination[1] = UInt8(truncatingIfNeeded: bits >> 8)
                destination += 2
            }
        }

        let wrote = AMRing_write(ring, scratch, blockSize)
        if wrote != blockSize {
            // Should be unreachable given the free-space precheck, but if the
            // ring ever accepts less than a whole block we must still count it.
            producerDrops &+= 1
            droppedFrames &+= UInt64(frames)
        }
    }

    // Float32 -> signed PCM16, the format AndroidMic's messages.proto expects.
    //
    // Quality notes:
    //   * lrintf() rounds to nearest with the current FP rounding mode (round to
    //     nearest-even by default) instead of truncating, which removes the DC
    //     bias that plain `Int16(x)` truncation would introduce.
    //   * The scale is the full-scale positive magnitude (32767), so +1.0 maps
    //     to 32767 and -1.0 maps to -32767. We deliberately do NOT stretch to
    //     -32768: doing that asymmetrically adds even-order distortion. The
    //     clamp below keeps the mapping symmetric about zero.
    //   * NaN and infinities are mapped to 0 (silence) rather than propagating a
    //     garbage sample.
    //   * The explicit clamp runs before the conversion so lrintf never sees a
    //     value outside [-1, 1]; this makes the result independent of the FP
    //     rounding mode and of float->int conversion undefined behaviour.
    @inline(__always)
    private static func pcm16(from raw: Float) -> UInt16 {
        let value: Float
        if raw.isFinite {
            value = raw < -1 ? -1 : (raw > 1 ? 1 : raw)
        } else {
            value = 0
        }
        let scaled = value * 32767
        let sample = Int16(clamping: Int(lrintf(scaled)))
        return UInt16(bitPattern: sample)
    }

    // MARK: - Consumer (high-priority serial queue)

    private func startConsumer(client: NWConnection, sampleRate: UInt32) {
        // Only touch `consumerRunning` here; the render-thread counters are reset
        // by the caller before the engine starts, so the render thread is never
        // racing a reset.
        sendQueue.sync { consumerRunning = true }
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            self?.drainConsumer(client: client, sampleRate: sampleRate)
        }
        timer.resume()
        consumerTimer = timer
    }

    private func drainConsumer(client: NWConnection, sampleRate: UInt32) {
        guard consumerRunning, let ring = ring else { return }
        // Discard only when the backlog exceeds the configured stale threshold
        // (by construction larger than the ring, so this is a safety valve, not
        // a normal-path action); see backlogDiscard_* above.
        let discardThreshold = Int(sampleRate)
            * MicrophoneStreamer.backlogDiscard_bytesPerSecond
            * MicrophoneStreamer.backlogDiscard_milliseconds / 1000
        var passes = 0
        var discardedBlocks = 0
        var discardedFramesThisPass = 0
        while passes < 16, consumerRunning {
            passes += 1
            guard AMRing_available(ring) >= 2 else { break }
            var header = [UInt8](repeating: 0, count: 2)
            let headerRead = header.withUnsafeMutableBytes { AMRing_read(ring, $0.baseAddress, 2) }
            guard headerRead == 2 else { break }
            let frames = Int(header[0]) | (Int(header[1]) << 8)
            guard frames > 0, frames <= MicrophoneStreamer.maxFramesPerBlock else {
                // Unreachable in normal operation: the producer caps frames and
                // writes whole blocks. If we ever see it, stop to avoid mis-
                // framing; teardown will destroy the ring anyway.
                break
            }
            let byteCount = frames * 2
            guard AMRing_available(ring) >= byteCount else {
                // A block is written atomically, so a short body can only mean
                // teardown is in progress; stop touching the ring.
                break
            }
            // After a scheduling stall, discard old whole blocks rather than
            // sending hundreds of milliseconds of stale microphone audio.
            if AMRing_available(ring) > discardThreshold {
                _ = AMRing_discard(ring, byteCount)
                discardedBlocks += 1
                discardedFramesThisPass += frames
                continue
            }
            var pcm = [UInt8](repeating: 0, count: byteCount)
            let bodyRead = pcm.withUnsafeMutableBytes { AMRing_read(ring, $0.baseAddress, byteCount) }
            guard bodyRead == byteCount else { break }
            let packet = AudioPacketEncoder.frame(pcm: Data(pcm), sampleRate: sampleRate)
            guard reserveSendSlot() else {
                // Congested: drop this block (bounded loss) instead of piling up.
                congestionDrops &+= 1
                continue
            }
            sendPacket(packet, client: client)
            sentBlocks &+= 1
        }
        if discardedBlocks > 0 {
            consumerDiscards &+= UInt64(discardedBlocks)
            if discardedBlocks >= 8 {
                publish("网络或系统调度抖动，已丢弃 \(discardedFramesThisPass) 帧旧音频（累计 \(consumerDiscards) 块）")
            }
        }
        reportStatsIfDue()
    }

    // Periodic, low-rate observability: surface producer and consumer drop
    // counters so continuous loss is visible in the UI instead of silent. Runs
    // on `sendQueue`, once every ~5 s, so it is cheap.
    private func reportStatsIfDue() {
        let now = DispatchTime.now()
        let elapsedMs = (now.uptimeNanoseconds &- lastStatsReport.uptimeNanoseconds) / 1_000_000
        guard elapsedMs >= 5000 else { return }
        lastStatsReport = now
        guard producerDrops > 0 || consumerDiscards > 0 || congestionDrops > 0 else { return }
        publish("已发送 \(sentBlocks) 块 · 采集丢 \(producerDrops)（\(droppedFrames) 帧）· 拥塞丢 \(congestionDrops) · 过期丢 \(consumerDiscards)")
    }

    private func reserveSendSlot() -> Bool {
        // `inFlight` is mutated only on `queue` from the send completion and
        // read here on `sendQueue`. Use an os_unfair_lock-free atomic via a
        // serial hop is overkill for a small counter; guard it with a lock
        // because it is not on the render thread.
        slotLock.lock()
        defer { slotLock.unlock() }
        if inFlight >= MicrophoneStreamer.maxInFlight { return false }
        inFlight += 1
        return true
    }

    private func releaseSendSlot() {
        slotLock.lock()
        if inFlight > 0 { inFlight -= 1 }
        slotLock.unlock()
    }

    private func sendPacket(_ packet: Data, client: NWConnection) {
        client.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            guard self.connection === client else { return }
            self.releaseSendSlot()
            // `client` is only valid as a comparison here; the connection
            // identity check happens on the queue via `self.connection`.
            self.queue.async {
                if let error = error {
                    guard self.connection === client else { return }
                    self.fail(error.localizedDescription)
                }
            }
        })
    }

    private let slotLock = NSLock()

    private func watchDisconnect(client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self = self, self.connection === client else { return }
            if let error = error { self.fail(error.localizedDescription) }
            else if complete { self.fail("电脑已断开，请重新连接") }
            else { self.watchDisconnect(client: client) }
        }
    }

    // MARK: - Teardown

    // Runs on `queue`. Ordering matters: stop the render callback and the
    // consumer BEFORE releasing the ring/scratch, and make sure any in-flight
    // consumer pass has finished via a barrier sync on `sendQueue`.
    private func shutdown() {
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil

        connectionTimeout?.cancel()
        connectionTimeout = nil

        consumerTimer?.cancel()
        consumerTimer = nil
        // Drain any event handler already running on sendQueue so it can no
        // longer touch the ring while we destroy it below.
        sendQueue.sync { consumerRunning = false }

        // Stop the engine AFTER the consumer: engine.stop() waits for the
        // current render callback to return, after which enqueueRealtime cannot
        // run again.
        engine?.stop()
        engine = nil

        old?.cancel()

        slotLock.lock()
        inFlight = 0
        slotLock.unlock()

        if let ring = ring { AMRing_destroy(ring) }
        ring = nil
        if let scratch = scratch { scratch.deallocate() }
        scratch = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        let id = transportAttempt
        shutdown()
        DispatchQueue.main.async {
            guard self.attempt == id else { return }
            self.attempt = nil
            self.isRunning = false
            self.status = "失败：\(message)"
        }
    }

    private func publish(_ message: String) {
        let id = transportAttempt
        DispatchQueue.main.async {
            guard self.attempt == id else { return }
            self.status = message
        }
    }
}
