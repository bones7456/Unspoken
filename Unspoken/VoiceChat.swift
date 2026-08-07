//
//  VoiceChat.swift
//  Unspoken
//
//  Voice audio pipeline shared by the walkie-talkie (live streaming) and the
//  offline voice-message (single file) paths:
//    • VoiceAudioSession  — one shared AVAudioSession held for the whole voice lifecycle
//    • PCMRingBuffer      — real-time-safe hand-off from the mic tap to the encoder queue
//    • VoiceCapture       — mic → AAC/m4a, either ~1s streamed segments or one whole file
//    • VoiceStreamPlayer  — receiver-side jitter buffer + gapless-ish playback of live segments
//    • VoiceMessagePlayer — play/pause a completed voice-message bubble (observed by MessageView)
//

import Foundation
import AVFoundation
import os

// MARK: - Helpers

/// Duration of an AAC/m4a blob, read without playing it. 0 if unreadable.
func voiceDurationOf(_ data: Data) -> TimeInterval {
    (try? AVAudioPlayer(data: data))?.duration ?? 0
}

/// "m:ss" for durations shown in bubbles and walkie-talkie summaries.
func formatVoiceDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - VoiceAudioSession (one session for capture *and* playback)

/// Reference-counted owner of the app's AVAudioSession while any voice activity is running.
///
/// Capture and playback must not configure the session for themselves: a walkie-talkie has both
/// happening at once. If playback switched the category to `.playback` it would knock the mic off
/// the route and silence the local transmission mid-sentence, and deactivating the session when
/// the PTT button is released would cut the peer's playback short. So the session is configured
/// once as `.playAndRecord` (+ `.mixWithOthers`), stays that way for as long as *anything* is
/// capturing or playing, and is only deactivated when the last holder lets go.
final class VoiceAudioSession {
    static let shared = VoiceAudioSession()
    private init() {}

    private let lock = NSLock()
    private var holders = 0

    /// Balance every `acquire()` with exactly one `release()`.
    func acquire() {
        lock.lock()
        defer { lock.unlock() }
        holders += 1
        guard holders == 1 else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("VoiceAudioSession.acquire error: \(error)")
        }
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - PCMRingBuffer (audio tap → encoder queue)

/// Fixed-capacity mono float ring buffer: written by the mic tap, drained by the encoder queue.
///
/// The tap callback runs on a real-time audio thread where file I/O, allocation and blocking are
/// all forbidden, so the only thing that happens there is a memcpy into preallocated storage under
/// a very short `os_unfair_lock` (which donates priority, so the tap can never end up waiting on
/// the lower-priority consumer). Multi-channel input is downmixed to mono on the way in — voice
/// only ever needs one channel and it keeps both sides of the buffer a straight memcpy.
///
/// On overflow (consumer stalled for longer than the buffer holds) the oldest samples are dropped
/// rather than blocking the tap.
final class PCMRingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let mixdown: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mixdownCapacity: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var head = 0      // next write position
    private var filled = 0    // readable samples

    init(capacityFrames: Int, maxTapFrames: Int = 16384) {
        capacity = max(1, capacityFrames)
        mixdownCapacity = max(1, maxTapFrames)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        mixdown = .allocate(capacity: mixdownCapacity)
        mixdown.initialize(repeating: 0, count: mixdownCapacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        mixdown.deinitialize(count: mixdownCapacity)
        mixdown.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Producer side — called from the audio tap thread only.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, frames <= mixdownCapacity else { return }
        let channels = Int(buffer.format.channelCount)

        let source: UnsafePointer<Float>
        if channels <= 1 {
            source = UnsafePointer(channelData[0])
        } else if buffer.format.isInterleaved {
            let interleaved = channelData[0]
            let scale = 1 / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[f * channels + c] }
                mixdown[f] = sum * scale
            }
            source = UnsafePointer(mixdown)
        } else {
            mixdown.update(from: channelData[0], count: frames)
            for c in 1..<channels {
                let plane = channelData[c]
                for f in 0..<frames { mixdown[f] += plane[f] }
            }
            let scale = 1 / Float(channels)
            for f in 0..<frames { mixdown[f] *= scale }
            source = UnsafePointer(mixdown)
        }
        append(source, count: frames)
    }

    private func append(_ src: UnsafePointer<Float>, count n: Int) {
        guard n > 0, n <= capacity else { return }
        os_unfair_lock_lock(lock)
        let first = min(n, capacity - head)
        storage.advanced(by: head).update(from: src, count: first)
        if first < n { storage.update(from: src.advanced(by: first), count: n - first) }
        head = (head + n) % capacity
        filled = min(filled + n, capacity)   // overflow drops the oldest samples
        os_unfair_lock_unlock(lock)
    }

    /// Consumer side — fills `buffer` (mono float32) with what is available, up to its capacity,
    /// and returns the frame count written.
    @discardableResult
    func read(into buffer: AVAudioPCMBuffer) -> Int {
        guard let dst = buffer.floatChannelData?[0] else { return 0 }
        let wanted = Int(buffer.frameCapacity)
        os_unfair_lock_lock(lock)
        let n = min(wanted, filled)
        if n > 0 {
            let tail = (head - filled + capacity) % capacity
            let first = min(n, capacity - tail)
            dst.update(from: storage.advanced(by: tail), count: first)
            if first < n { dst.advanced(by: first).update(from: storage, count: n - first) }
            filled -= n
        }
        os_unfair_lock_unlock(lock)
        buffer.frameLength = AVAudioFrameCount(n)
        return n
    }
}

// MARK: - VoiceCapture (mic → AAC segments or one file)

/// Captures microphone audio through AVAudioEngine and encodes it to AAC/m4a.
/// In `.stream` mode it emits a self-contained ~1s segment via `onSegment` roughly
/// once a second; in `.file` mode it accumulates the whole recording and emits it
/// once via `onFileComplete`. All callbacks are delivered on the main thread.
///
/// The mic tap only pushes PCM into a ring buffer; encoding, segment rotation and every disk
/// access happen on `ioQueue`, driven by a timer that drains the ring ~10x a second.
final class VoiceCapture {
    enum Mode { case stream, file }

    /// Called on the main thread with each ~1s AAC segment (stream mode).
    var onSegment: ((Data) -> Void)?
    /// Called on the main thread with the whole recording + its duration (file mode).
    var onFileComplete: ((Data, TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    /// Everything that encodes or touches the filesystem runs here — never on the tap thread.
    private let ioQueue = DispatchQueue(label: "com.unspoken.voice.capture", qos: .userInitiated)

    private let drainInterval: DispatchTimeInterval = .milliseconds(100)
    private let drainChunkFrames = 8192

    // Main-thread state
    private var running = false
    private var sessionHeld = false
    private var drainTimer: DispatchSourceTimer?

    // ioQueue-only state
    private var ring: PCMRingBuffer?
    private var drainBuffer: AVAudioPCMBuffer?
    private var encodeSettings: [String: Any] = [:]
    private var mode: Mode = .stream
    private var sampleRate: Double = 48000
    private var segmentFrameThreshold: AVAudioFramePosition = 48000  // 1s worth of frames
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var framesInSegment: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0

    // MARK: Start / stop

    /// Requests mic permission, takes the shared session and starts capturing.
    /// `completion(true)` on the main thread once audio is flowing, `false` if denied/failed.
    func start(mode: Mode, completion: @escaping (Bool) -> Void) {
        requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                guard granted else { completion(false); return }

                VoiceAudioSession.shared.acquire()
                self.sessionHeld = true

                let tapFormat = self.engine.inputNode.outputFormat(forBus: 0)
                let rate = tapFormat.sampleRate > 0 ? tapFormat.sampleRate : 48000
                guard tapFormat.channelCount > 0 else {
                    self.releaseSession()
                    completion(false)
                    return
                }

                let ring = PCMRingBuffer(capacityFrames: Int(rate * 2))   // ~2s of headroom
                self.configureEncoder(mode: mode, rate: rate, ring: ring)

                do {
                    self.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                        ring.write(buffer)      // memcpy only — the encoder runs on ioQueue
                    }
                    self.engine.prepare()
                    try self.engine.start()
                } catch {
                    print("VoiceCapture.start error: \(error)")
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.ioQueue.async { self.discardEncoder() }
                    self.releaseSession()
                    completion(false)
                    return
                }
                self.running = true
                self.startDrainTimer()
                completion(true)
            }
        }
    }

    /// Stops capturing and flushes the trailing segment / whole file, then calls
    /// `completion` on the main thread *after* the final emission is queued so callers
    /// can safely send an end marker knowing the last segment went out first.
    func stop(completion: @escaping () -> Void) {
        guard running else {
            releaseSession()
            DispatchQueue.main.async(execute: completion)
            return
        }
        running = false
        drainTimer?.cancel()
        drainTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Released here rather than after the flush below: the flush is pure file I/O and needs no
        // session, and deferring it would let a quick re-press acquire before this release lands.
        releaseSession()

        ioQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async(execute: completion); return }
            self.drain()                    // flush whatever the tap left in the ring
            let url = self.currentURL
            let mode = self.mode
            let duration = Double(self.totalFrames) / self.sampleRate
            let partialFrames = self.framesInSegment
            self.currentFile = nil          // finalize/flush the m4a on disk
            self.currentURL = nil
            self.ring = nil
            self.drainBuffer = nil

            var payload: Data?
            if let url {
                payload = try? Data(contentsOf: url)
                try? FileManager.default.removeItem(at: url)
            }

            DispatchQueue.main.async {
                if let data = payload, !data.isEmpty {
                    if mode == .file {
                        self.onFileComplete?(data, duration)
                    } else if partialFrames > 0 {
                        self.onSegment?(data)
                    }
                }
                completion()
            }
        }
    }

    // MARK: Internals

    private func releaseSession() {
        guard sessionHeld else { return }
        sessionHeld = false
        VoiceAudioSession.shared.release()
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()
    }

    private func configureEncoder(mode: Mode, rate: Double, ring: PCMRingBuffer) {
        ioQueue.sync {
            self.mode = mode
            self.sampleRate = rate
            self.segmentFrameThreshold = AVAudioFramePosition(rate)   // ~1s per streamed segment
            self.framesInSegment = 0
            self.totalFrames = 0
            self.ring = ring
            // Mono throughout: PCMRingBuffer already downmixed whatever the input route gave us.
            self.encodeSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000
            ]
            if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: 1, interleaved: false) {
                self.drainBuffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                                    frameCapacity: AVAudioFrameCount(self.drainChunkFrames))
            }
            self.startNewFile()
        }
    }

    /// Encoder-queue only: drains everything the tap has produced, rotating segments as they fill.
    private func drain() {
        guard let ring, let buffer = drainBuffer else { return }
        while true {
            let frames = ring.read(into: buffer)
            guard frames > 0 else { return }
            writeFrames(buffer, frames: AVAudioFramePosition(frames))
            if frames < Int(buffer.frameCapacity) { return }
        }
    }

    private func writeFrames(_ buffer: AVAudioPCMBuffer, frames: AVAudioFramePosition) {
        guard let file = currentFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("VoiceCapture.write error: \(error)")
            return
        }
        framesInSegment += frames
        totalFrames += frames
        if mode == .stream && framesInSegment >= segmentFrameThreshold { rotateSegment() }
    }

    /// Finalize the current segment, emit its bytes, and open a fresh file.
    private func rotateSegment() {
        guard let url = currentURL else { return }
        currentFile = nil          // flush to disk
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        framesInSegment = 0
        if let data, !data.isEmpty {
            DispatchQueue.main.async { self.onSegment?(data) }
        }
        startNewFile()
    }

    private func startNewFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt_\(UUID().uuidString).m4a")
        do {
            // Force the writer's processing format to match the drain buffer so writes never throw.
            currentFile = try AVAudioFile(forWriting: url, settings: encodeSettings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
            currentURL = url
        } catch {
            print("VoiceCapture.startNewFile error: \(error)")
            currentFile = nil
            currentURL = nil
        }
    }

    /// Encoder-queue only: throw away a half-configured capture (engine failed to start).
    private func discardEncoder() {
        currentFile = nil
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        currentURL = nil
        ring = nil
        drainBuffer = nil
    }

    private func requestPermission(_ handler: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handler)
        }
    }
}

// MARK: - VoiceStreamPlayer (receiver jitter buffer + playback)

/// Buffers incoming live walkie-talkie segments and plays them back-to-back through
/// an AVQueuePlayer. Playback starts only after `bufferTarget` segments have arrived
/// (~2s cushion) so ordinary network jitter never starves the queue. Must be used on main.
final class VoiceStreamPlayer {
    /// Called on the main thread once the stream has ended *and* the queue has drained.
    var onFinished: (() -> Void)?

    private let player = AVQueuePlayer()
    private var buffered: [AVPlayerItem] = []
    private var tempURLs: [URL] = []
    private var started = false
    private var ended = false
    private var sessionHeld = false
    private var observer: NSKeyValueObservation?
    private let bufferTarget = 2       // ~2 x 1s segments before playback begins

    init() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func enqueue(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr_\(UUID().uuidString).m4a")
        do { try data.write(to: url) } catch { return }
        tempURLs.append(url)
        let item = AVPlayerItem(url: url)

        if started {
            player.insert(item, after: player.items().last)
            if player.timeControlStatus != .playing { player.play() }  // resume after an underrun
        } else {
            buffered.append(item)
            if buffered.count >= bufferTarget { startPlayback() }
        }
    }

    /// The sender released the button (voice_end). Start immediately if still buffering,
    /// otherwise just let the queue drain and fire `onFinished`.
    func finish() {
        ended = true
        if !started { startPlayback() }
        else if player.currentItem == nil { fireFinished() }
    }

    /// Tear down without firing onFinished (peer dropped / room closed).
    func reset() {
        observer = nil
        player.pause()
        player.removeAllItems()
        cleanupFiles()
        buffered.removeAll()
        started = false
        ended = false
        releaseSession()
    }

    private func startPlayback() {
        guard !started else { return }
        started = true
        for item in buffered { player.insert(item, after: player.items().last) }
        buffered.removeAll()

        // A press too short to produce even one segment ends here: finish now rather than leave
        // the player half-started, where the next stream's first underrun would fire onFinished.
        guard !player.items().isEmpty else {
            fireFinished()
            return
        }

        if !sessionHeld {
            VoiceAudioSession.shared.acquire()
            sessionHeld = true
        }

        observer = player.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            guard let self else { return }
            if p.currentItem == nil { self.fireFinished() }
        }
        player.play()
    }

    private func fireFinished() {
        guard ended, started else { return }
        observer = nil
        cleanupFiles()
        started = false
        ended = false
        releaseSession()
        onFinished?()
    }

    private func releaseSession() {
        guard sessionHeld else { return }
        sessionHeld = false
        VoiceAudioSession.shared.release()
    }

    private func cleanupFiles() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs.removeAll()
    }
}

// MARK: - VoiceMessagePlayer (per-bubble playback)

/// Plays a single completed voice-message bubble at a time. MessageView observes this
/// to render the play/pause state and progress of whichever message is playing.
final class VoiceMessagePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingId: UUID?
    @Published var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var sessionHeld = false

    func toggle(id: UUID, data: Data) {
        if playingId == id { stop() } else { start(id: id, data: data) }
    }

    private func start(id: UUID, data: Data) {
        stop()
        VoiceAudioSession.shared.acquire()
        sessionHeld = true
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingId = id
            progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        } catch {
            print("VoiceMessagePlayer.start error: \(error)")
            stop()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingId = nil
        progress = 0
        if sessionHeld {
            sessionHeld = false
            VoiceAudioSession.shared.release()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}
