//
//  VoiceTranscription.swift
//  Unspoken
//
//  On-device transcription of voice messages (iOS 26+):
//    • MemoryAudioDecoder — AAC/m4a bytes → PCM without ever writing a file
//    • VoiceTranscriber   — SpeechAnalyzer front-end, one clip at a time
//
//  The audio never leaves the device and never touches disk. `SpeechTranscriber` /
//  `DictationTranscriber` have no server mode at all — unlike the old `SFSpeechRecognizer`,
//  which uploads to Apple unless `requiresOnDeviceRecognition` is set — so there is no
//  "falls back to the network" path to guard against here. The only network access in this
//  file is the one-time language-model download, which the user has to confirm first.
//

import Foundation
import AVFoundation
import AudioToolbox
import Speech

// MARK: - Debug logging

/// Diagnostics for the transcription path. Every line is prefixed `[VT]` so a console can be
/// filtered down to just this feature. Debug builds only.
@inline(__always)
func vtLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[VT] \(message())")
    #endif
}

/// Full error detail — `localizedDescription` alone routinely hides the domain/code that says
/// what actually went wrong inside Speech/AssetInventory.
func vtDescribe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(type(of: error)): \(String(describing: error)) | domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)"
}

// MARK: - In-memory decoding

enum MemoryDecodeError: Error {
    case open(OSStatus), wrap(OSStatus), setFormat(OSStatus), read(OSStatus), allocFailed
}

/// Decodes an in-memory AAC/m4a blob to PCM in `targetFormat`, without writing a file.
///
/// The analyzer's convenient entry points want an `AVAudioFile`, which can only be built from a
/// URL — i.e. from disk. `AudioFileOpenWithCallbacks` instead lets AudioToolbox parse a container
/// that lives in a `Data` through read/getSize callbacks, and `ExtAudioFileWrapAudioFileID` layers
/// the usual decode + sample-rate conversion on top of that. A received voice message therefore
/// goes decrypt → PCM → transcript entirely in memory.
final class MemoryAudioDecoder {
    private let data: Data

    init(data: Data) { self.data = data }

    private static let readProc: AudioFile_ReadProc = { clientData, inPosition, requestCount, buffer, actualCount in
        let me = Unmanaged<MemoryAudioDecoder>.fromOpaque(clientData).takeUnretainedValue()
        let total = Int64(me.data.count)
        guard inPosition >= 0, inPosition < total else {
            actualCount.pointee = 0
            return kAudioFileEndOfFileError
        }
        let available = min(Int64(requestCount), total - inPosition)
        me.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.copyMemory(from: base.advanced(by: Int(inPosition)), byteCount: Int(available))
        }
        actualCount.pointee = UInt32(available)
        return noErr
    }

    private static let getSizeProc: AudioFile_GetSizeProc = { clientData in
        Int64(Unmanaged<MemoryAudioDecoder>.fromOpaque(clientData).takeUnretainedValue().data.count)
    }

    /// Decodes the whole blob. The caller bounds the duration (see `VoiceTranscriber.maxDuration`),
    /// so holding every buffer at once stays in the low tens of MB at worst.
    func decodeAll(to targetFormat: AVAudioFormat,
                   chunkFrames: AVAudioFrameCount = 8192) throws -> [AVAudioPCMBuffer] {
        var fileID: AudioFileID?
        let me = Unmanaged.passUnretained(self).toOpaque()
        var st = AudioFileOpenWithCallbacks(me, Self.readProc, nil, Self.getSizeProc, nil,
                                            kAudioFileM4AType, &fileID)
        guard st == noErr, let fileID else { throw MemoryDecodeError.open(st) }
        defer { AudioFileClose(fileID) }

        var ext: ExtAudioFileRef?
        st = ExtAudioFileWrapAudioFileID(fileID, false, &ext)
        guard st == noErr, let ext else { throw MemoryDecodeError.wrap(st) }
        defer { ExtAudioFileDispose(ext) }

        var asbd = targetFormat.streamDescription.pointee
        st = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd)
        guard st == noErr else { throw MemoryDecodeError.setFormat(st) }

        vtLog("decode: target format \(targetFormat) (\(targetFormat.sampleRate) Hz, \(targetFormat.channelCount) ch, interleaved=\(targetFormat.isInterleaved))")
        var out: [AVAudioPCMBuffer] = []
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames) else {
                throw MemoryDecodeError.allocFailed
            }
            // mDataByteSize is derived from frameLength, not frameCapacity, so the buffer has to be
            // opened up to its full length *before* the read — otherwise ExtAudioFileRead sees a
            // zero-byte destination, returns 0 frames, and the transcript comes back silently empty.
            buf.frameLength = chunkFrames
            var frames = chunkFrames
            st = ExtAudioFileRead(ext, &frames, buf.mutableAudioBufferList)
            guard st == noErr else { throw MemoryDecodeError.read(st) }
            if frames == 0 { break }
            buf.frameLength = frames
            out.append(buf)
        }
        let totalFrames = out.reduce(0) { $0 + Int($1.frameLength) }
        vtLog("decode: \(out.count) buffers, \(totalFrames) frames (\(String(format: "%.2f", Double(totalFrames) / targetFormat.sampleRate))s)")
        return out
    }
}

// MARK: - Transcriber

@available(iOS 26.0, *)
enum VoiceTranscriptionError: LocalizedError {
    case localeUnsupported(Locale)
    case modelNotInstalled(Locale)
    case modelUnusable(Locale)
    case downloadDidNotInstall(Locale)
    case assetsUnavailable
    case tooLong(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let l):
            return "\(ChatViewModel.transcriptLocaleName(l)) can't be transcribed on this device."
        case .modelNotInstalled(let l):
            return "The \(ChatViewModel.transcriptLocaleName(l)) speech model isn't installed."
        case .modelUnusable(let l):
            // Registered as installed, but every engine reports no compatible audio format.
            // Re-downloading cannot help, so this must not be reported as "needs download".
            #if targetEnvironment(simulator)
            return "The \(ChatViewModel.transcriptLocaleName(l)) model can't be loaded in the Simulator. Speech models only work on a real device."
            #else
            return "The \(ChatViewModel.transcriptLocaleName(l)) model is installed but this device can't load it."
            #endif
        case .downloadDidNotInstall(let l):
            return "The \(ChatViewModel.transcriptLocaleName(l)) model finished downloading but still isn't usable."
        case .assetsUnavailable:
            return "The speech model isn't available."
        case .tooLong:
            return "This recording is too long to transcribe."
        }
    }
}

/// Serialises transcription: an actor, so tapping several bubbles queues them up instead of
/// letting them contend for the Neural Engine.
@available(iOS 26.0, *)
actor VoiceTranscriber {
    static let shared = VoiceTranscriber()

    /// Roughly 19 MB of float PCM at the analyzer's preferred rate. Voice messages are seconds
    /// long in practice; this only exists so a pathological clip can't balloon memory.
    static let maxDuration: TimeInterval = 300

    // MARK: - Engines

    /// The two on-device engines, declared best-quality first (`allCases` order is the preference
    /// order). Their assets are installed **separately**: a locale present for one says nothing
    /// about the other, which is exactly the trap that made transcription fail with
    /// "no compatible audio format" — see `plan(for:)`.
    enum Engine: CaseIterable {
        case speech      // SpeechTranscriber — the new large model, 30 locales, punctuation
        case dictation   // DictationTranscriber — the older dictation assets, 54 locales

        func module(for locale: Locale) -> any SpeechModule {
            switch self {
            case .speech:
                return SpeechTranscriber(locale: locale, preset: .transcription)
            case .dictation:
                // .longDictation, not .shortDictation: the short preset returns an empty
                // transcript for an ordinary few-second voice message.
                return DictationTranscriber(locale: locale, preset: .longDictation)
            }
        }

        func supportedLocales() async -> [Locale] {
            switch self {
            case .speech:    return await SpeechTranscriber.supportedLocales
            case .dictation: return await DictationTranscriber.supportedLocales
            }
        }

        func installedLocales() async -> [Locale] {
            switch self {
            case .speech:    return await SpeechTranscriber.installedLocales
            case .dictation: return await DictationTranscriber.installedLocales
            }
        }

        func supports(_ locale: Locale) async -> Bool {
            let tag = locale.identifier(.bcp47)
            return await supportedLocales().contains { $0.identifier(.bcp47) == tag }
        }

        func hasAssets(for locale: Locale) async -> Bool {
            let tag = locale.identifier(.bcp47)
            return await installedLocales().contains { $0.identifier(.bcp47) == tag }
        }
    }

    /// Which engine to run `locale` on, and whether its model has to be fetched first.
    ///
    /// An engine whose assets are **already on the device** beats a better one that would have to
    /// be downloaded: a phone whose owner dictates in Chinese already carries zh-CN for
    /// `DictationTranscriber`, so transcribing costs no download and no network at all. Only when
    /// neither engine has the language installed do we fall back to the best one and ask.
    /// Cheap one-liner for the start of a run. The full dump probes every installed locale for a
    /// loadable model, which on a well-stocked phone is 20+ extra async calls — too expensive to
    /// pay on every tap, so it is kept for the failure paths.
    static func logEnvironmentSummary() async {
        for engine in Engine.allCases {
            let supported = await engine.supportedLocales().count
            let installed = await engine.installedLocales().map { $0.identifier(.bcp47) }.sorted()
            vtLog("env: \(engine) supported=\(supported) installed=[\(installed.joined(separator: " "))]")
        }
    }

    /// Full dump, including whether each installed locale's model actually loads. "Installed" is
    /// only a registry entry and the two genuinely disagree — the Simulator reports models as
    /// installed and can load none of them. Called on failures, where that distinction is the
    /// whole answer.
    static func logEnvironment() async {
        for engine in Engine.allCases {
            let supported = await engine.supportedLocales().map { $0.identifier(.bcp47) }.sorted()
            let installedLocales = await engine.installedLocales()
            let installed = installedLocales.map { $0.identifier(.bcp47) }.sorted()
            vtLog("env: \(engine) supported=\(supported.count) installed=\(installed.count) -> [\(installed.joined(separator: " "))]")
            for locale in installedLocales {
                let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module(for: locale)])
                vtLog("env:   \(engine)/\(locale.identifier(.bcp47)) loadable=\(fmt != nil)")
            }
        }
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
        vtLog("env: reservedLocales=\(reserved) max=\(AssetInventory.maximumReservedLocales)")
    }

    /// Engines that support `locale`, best quality first.
    static func supportingEngines(for locale: Locale) async -> [Engine] {
        var out: [Engine] = []
        for engine in Engine.allCases {
            if await engine.supports(locale) { out.append(engine) }
        }
        return out
    }

    static func plan(for locale: Locale) async throws -> (engine: Engine, needsDownload: Bool) {
        let tag = locale.identifier(.bcp47)
        var supported: [Engine] = []
        for engine in Engine.allCases {
            let ok = await engine.supports(locale)
            let has = await engine.hasAssets(for: locale)
            vtLog("plan(\(tag)): \(engine) supports=\(ok) hasAssets=\(has)")
            if ok { supported.append(engine) }
        }
        guard !supported.isEmpty else {
            vtLog("plan(\(tag)): NO engine supports this locale")
            throw VoiceTranscriptionError.localeUnsupported(locale)
        }
        // Anything already on the device wins outright: best quality among the free options.
        for engine in supported {
            if await engine.hasAssets(for: locale) {
                vtLog("plan(\(tag)): -> \(engine), no download needed")
                return (engine, false)
            }
        }
        // Nothing installed, so somebody is about to wait on a download. Measured: the dictation
        // model for zh-CN takes ~110 s, and `.speech` is Apple's much larger Apple-Intelligence
        // model. For a "I can't listen right now" convenience, finishing beats punctuation — and
        // `.speech`'s 30 locales are a subset of `.dictation`'s 54, so this branch always exists.
        // A phone that already carries the better model still gets it, via the loop above.
        if supported.contains(.dictation) {
            vtLog("plan(\(tag)): -> dictation, DOWNLOAD needed")
            return (.dictation, true)
        }
        vtLog("plan(\(tag)): -> \(supported[0]), DOWNLOAD needed")
        return (supported[0], true)
    }

    // MARK: - Locale helpers

    /// Every locale either engine can handle, best-engine-first.
    static func supportedLocales() async -> [Locale] {
        var seen = Set<String>()
        var out: [Locale] = []
        for engine in Engine.allCases {
            for locale in await engine.supportedLocales()
            where seen.insert(locale.identifier(.bcp47)).inserted {
                out.append(locale)
            }
        }
        return out
    }

    /// Locales transcribable right now with no download — the union is correct here because
    /// `plan(for:)` picks whichever engine actually holds the assets.
    static func installedLocales() async -> [Locale] {
        var out: [Locale] = []
        for engine in Engine.allCases { out += await engine.installedLocales() }
        return out
    }

    static func isReady(_ locale: Locale) async -> Bool {
        guard let plan = try? await plan(for: locale) else { return false }
        return !plan.needsDownload
    }

    /// Maps an arbitrary locale onto one an engine actually supports: exact BCP-47, then same
    /// language + region, then the language's likely region, then any installed variant.
    static func resolve(_ wanted: Locale, in supported: [Locale], installed: [Locale]) -> Locale? {
        let tag = wanted.identifier(.bcp47)
        if let hit = supported.first(where: { $0.identifier(.bcp47) == tag }) { return hit }
        let lang = wanted.language.languageCode?.identifier
        let region = wanted.region?.identifier
        let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
        if let hit = sameLang.first(where: { $0.region?.identifier == region }) { return hit }
        // No region match: take CLDR's likely region for the language rather than whichever
        // variant happens to come first (which would resolve "en" to en-ZA). `wanted.language`
        // rather than the bare language code, so a script subtag survives and zh-Hant lands on
        // zh-TW instead of zh-CN.
        let likelyRegion = wanted.language.maximalIdentifier
            .split(separator: "-").last.map(String.init)
        if let hit = sameLang.first(where: { $0.region?.identifier == likelyRegion }) { return hit }
        let installedTags = Set(installed.map { $0.identifier(.bcp47) })
        return sameLang.first(where: { installedTags.contains($0.identifier(.bcp47)) }) ?? sameLang.first
    }

    // MARK: - Work

    /// Downloads and installs the model for `locale`. Only call this after the user has agreed —
    /// it is the one moment this feature touches the network.
    ///
    /// `onProgress` reports `(fractionCompleted, elapsedSeconds)`. On device
    /// `AssetInstallationRequest.progress` animates normally (~1 minute to 100%), but it is not
    /// dependable everywhere — on macOS it stays `totalUnitCount == 1 / completedUnitCount == 0`
    /// for the entire ~110 s download and only flips after `downloadAndInstall()` has returned.
    /// Hence both numbers: the bubble draws a real bar when the fraction moves and falls back to
    /// a spinner plus an elapsed clock when it doesn't, so it never looks hung either way.
    func downloadAssets(for locale: Locale,
                        onProgress: @escaping (Double, Int) -> Void) async throws {
        let tag = locale.identifier(.bcp47)
        let plan = try await Self.plan(for: locale)
        guard plan.needsDownload else {
            vtLog("download(\(tag)): already installed via \(plan.engine), nothing to do")
            return
        }
        let module = plan.engine.module(for: locale)
        let status = await AssetInventory.status(forModules: [module])
        vtLog("download(\(tag)): engine=\(plan.engine) status=\(status), requesting installation…")
        let maybeRequest: AssetInstallationRequest?
        do {
            maybeRequest = try await AssetInventory.assetInstallationRequest(supporting: [module])
        } catch {
            vtLog("download(\(tag)): assetInstallationRequest THREW \(vtDescribe(error))")
            throw error
        }
        guard let request = maybeRequest else {
            vtLog("download(\(tag)): assetInstallationRequest returned nil")
            throw VoiceTranscriptionError.assetsUnavailable
        }
        let started = Date()
        let progress = request.progress
        var lastLogged = -1
        let ticker = Task {
            while !Task.isCancelled {
                let fraction = progress.isIndeterminate ? 0 : progress.fractionCompleted
                let elapsed = Int(Date().timeIntervalSince(started))
                if elapsed != lastLogged, elapsed % 2 == 0 {
                    lastLogged = elapsed
                    vtLog("download(\(tag)): t=\(elapsed)s fraction=\(fraction) total=\(progress.totalUnitCount) completed=\(progress.completedUnitCount) indeterminate=\(progress.isIndeterminate)")
                }
                await MainActor.run { onProgress(fraction, elapsed) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { ticker.cancel() }
        do {
            try await request.downloadAndInstall()
            vtLog("download(\(tag)): downloadAndInstall returned after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            vtLog("download(\(tag)): downloadAndInstall THREW after \(String(format: "%.1f", Date().timeIntervalSince(started)))s \(vtDescribe(error))")
            throw error
        }
        // Keep the model from being reclaimed under us. Capped at
        // AssetInventory.maximumReservedLocales (5); failing to reserve is not fatal.
        do {
            let ok = try await AssetInventory.reserve(locale: locale)
            let list = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
            vtLog("download(\(tag)): reserve -> \(ok); reservedLocales=\(list)")
        } catch {
            vtLog("download(\(tag)): reserve THREW \(vtDescribe(error))")
        }
        // downloadAndInstall() returning is not proof the locale became usable — say so rather
        // than falling through to a confusing "no compatible audio format" later.
        await Self.logEnvironment()
        guard await Self.isReady(locale) else {
            vtLog("download(\(tag)): STILL not ready after install")
            throw VoiceTranscriptionError.downloadDidNotInstall(locale)
        }
        vtLog("download(\(tag)): installed and ready")
    }

    /// Transcribes an in-memory AAC/m4a voice message. Nothing is written to disk.
    func transcribe(audio: Data, duration: TimeInterval, locale: Locale) async throws -> String {
        guard duration <= Self.maxDuration else { throw VoiceTranscriptionError.tooLong(duration) }

        let tag = locale.identifier(.bcp47)
        vtLog("transcribe(\(tag)): \(audio.count) bytes, \(String(format: "%.2f", duration))s")
        // Try every engine that supports the locale, not just the planned one: a model can be
        // registered as installed and still refuse to produce a compatible audio format, and the
        // other engine may well be fine.
        var chosen: (engine: Engine, module: any SpeechModule, format: AVAudioFormat)?
        var anyInstalled = false
        for engine in await Self.supportingEngines(for: locale) {
            let installed = await engine.hasAssets(for: locale)
            anyInstalled = anyInstalled || installed
            let candidate = engine.module(for: locale)
            if let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [candidate]) {
                chosen = (engine, candidate, fmt)
                break
            }
            vtLog("transcribe(\(tag)): \(engine) installed=\(installed) but no compatible format")
        }
        guard let (engine, module, format) = chosen else {
            await Self.logEnvironment()
            // Installed-but-unloadable is NOT a download problem. Reporting it as one sent the
            // bubble straight back to the download prompt, where pressing Download did nothing
            // visible and looped forever.
            if anyInstalled {
                vtLog("transcribe(\(tag)): installed but unusable — not a download problem")
                throw VoiceTranscriptionError.modelUnusable(locale)
            }
            vtLog("transcribe(\(tag)): no engine has assets — needs download")
            throw VoiceTranscriptionError.modelNotInstalled(locale)
        }
        vtLog("transcribe(\(tag)): engine=\(engine) format=\(format)")

        let buffers = try MemoryAudioDecoder(data: audio).decodeAll(to: format)
        try Task.checkCancellation()

        let stream = AsyncStream<AnalyzerInput> { cont in
            for b in buffers { cont.yield(AnalyzerInput(buffer: b)) }
            cont.finish()
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        // `results` is an AsyncSequence: it has to be subscribed before analysis starts, or the
        // early results are gone by the time we get there.
        let collector = Task { () -> String in
            var text = AttributedString()
            var count = 0
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results {
                        count += 1
                        vtLog("transcribe(\(tag)): result #\(count) final=\(r.isFinal) chars=\(String(r.text.characters).count)")
                        if r.isFinal { text += r.text }
                    }
                } else if let d = module as? DictationTranscriber {
                    for try await r in d.results {
                        count += 1
                        vtLog("transcribe(\(tag)): result #\(count) final=\(r.isFinal) chars=\(String(r.text.characters).count)")
                        if r.isFinal { text += r.text }
                    }
                }
            } catch {
                vtLog("transcribe(\(tag)): results stream THREW \(vtDescribe(error))")
                throw error
            }
            vtLog("transcribe(\(tag)): \(count) results total")
            return String(text.characters)
        }

        do {
            let end = try await analyzer.analyzeSequence(stream)
            vtLog("transcribe(\(tag)): analyzeSequence done, end=\(String(describing: end))")
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            vtLog("transcribe(\(tag)): analyzer THREW \(vtDescribe(error))")
            throw error
        }
        let out = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        vtLog("transcribe(\(tag)): FINAL \(out.count) chars: \"\(out.prefix(120))\"")
        return out
    }
}
