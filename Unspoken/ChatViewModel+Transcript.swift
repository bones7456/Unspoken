//
//  ChatViewModel+Transcript.swift
//  Unspoken
//
//  Voice-message transcription, receiver side and sender side alike (iOS 26+).
//
//  Everything here is local: the clip is already in `messages` as bytes, it is decoded and
//  recognised in memory (see VoiceTranscription.swift), and the resulting text is written back
//  into the same in-memory `Message`. Nothing is sent, nothing is persisted. A transcript is
//  therefore available even in a farewell room — `enterFarewell` clears `peerPublicKey`, which
//  closes the sending gate, but the audio and the recogniser don't need a peer.
//

import Foundation
import SwiftUI

extension ChatViewModel {
    static let transcriptLocaleKey = "transcriptLocale"

    // MARK: - Lifecycle

    /// Called from `leaveRoom()`; also used when re-running with a different language.
    func cancelAllTranscriptions() {
        transcriptTasks.values.forEach { $0.cancel() }
        transcriptTasks.removeAll()
    }

    func transcriptIndex(of messageId: UUID) -> Int? {
        messages.firstIndex { $0.id == messageId }
    }

    func setTranscript(_ messageId: UUID, _ state: TranscriptState) {
        guard let idx = transcriptIndex(of: messageId) else { return }
        messages[idx].transcript = state
    }

    // MARK: - Entry points from the bubble

    /// Tapping the transcript button. Expands or collapses the panel, and kicks off recognition
    /// the first time it is opened — collapsing keeps whatever text we already have.
    func toggleTranscript(messageId: UUID) {
        guard let idx = transcriptIndex(of: messageId) else {
            vtLog("toggle: message not found")
            return
        }
        messages[idx].transcriptExpanded.toggle()
        vtLog("toggle: expanded=\(messages[idx].transcriptExpanded) state=\(messages[idx].transcript)")
        guard messages[idx].transcriptExpanded, messages[idx].transcript == .none else { return }
        if #available(iOS 26.0, *) {
            runTranscript(messageId: messageId, allowDownload: false)
        } else {
            vtLog("toggle: iOS < 26, transcription unavailable")
        }
    }

    /// "Retry" after a failure, and the path taken when the language changes.
    @available(iOS 26.0, *)
    func retryTranscript(messageId: UUID) {
        vtLog("action: retry")
        runTranscript(messageId: messageId, allowDownload: false)
    }

    /// The user agreed to fetch the language model — the one moment this feature uses the network.
    @available(iOS 26.0, *)
    func confirmTranscriptDownload(messageId: UUID) {
        vtLog("action: user confirmed download")
        runTranscript(messageId: messageId, allowDownload: true)
    }

    // MARK: - Language

    /// The locale transcription runs in: the user's saved choice if there is one, otherwise the
    /// system language, normalised onto something an engine actually supports.
    @available(iOS 26.0, *)
    func resolveTranscriptLocale() async throws -> Locale {
        if let cached = await MainActor.run(body: { self.transcriptLocale }) { return cached }
        let saved = UserDefaults.standard.string(forKey: Self.transcriptLocaleKey)
        let wanted = saved.map { Locale(identifier: $0) } ?? Locale.current
        let supported = await VoiceTranscriber.supportedLocales()
        let installed = await VoiceTranscriber.installedLocales()
        guard let resolved = VoiceTranscriber.resolve(wanted, in: supported, installed: installed) else {
            vtLog("locale: saved=\(saved ?? "-") current=\(Locale.current.identifier) -> UNSUPPORTED")
            throw VoiceTranscriptionError.localeUnsupported(wanted)
        }
        vtLog("locale: saved=\(saved ?? "-") current=\(Locale.current.identifier) -> resolved=\(resolved.identifier(.bcp47))")
        await MainActor.run { self.transcriptLocale = resolved }
        return resolved
    }

    @available(iOS 26.0, *)
    func loadAvailableTranscriptLocales() {
        guard availableTranscriptLocales.isEmpty else { return }
        Task { [weak self] in
            let locales = await VoiceTranscriber.supportedLocales().sorted {
                Self.transcriptLocaleName($0).localizedCaseInsensitiveCompare(Self.transcriptLocaleName($1)) == .orderedAscending
            }
            guard let self else { return }
            await MainActor.run { self.availableTranscriptLocales = locales }
        }
    }

    /// Switching language re-runs every transcript that is currently on screen, so the user sees
    /// the effect of the change immediately rather than having to collapse and reopen each bubble.
    @available(iOS 26.0, *)
    func setTranscriptLocale(_ locale: Locale) {
        guard locale != transcriptLocale else { return }
        UserDefaults.standard.set(locale.identifier(.bcp47), forKey: Self.transcriptLocaleKey)
        transcriptLocale = locale
        cancelAllTranscriptions()
        for message in messages where message.transcriptExpanded && message.audioData != nil {
            setTranscript(message.id, .none)
            runTranscript(messageId: message.id, allowDownload: false)
        }
    }

    static func transcriptLocaleName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: - The run

    @available(iOS 26.0, *)
    private func runTranscript(messageId: UUID, allowDownload: Bool) {
        guard let idx = transcriptIndex(of: messageId),
              let audio = messages[idx].audioData else {
            vtLog("run: no message/audio for \(messageId)")
            return
        }
        let duration = messages[idx].audioDuration ?? 0
        transcriptTasks[messageId]?.cancel()
        messages[idx].transcript = .running
        vtLog("run: start allowDownload=\(allowDownload) audio=\(audio.count)B duration=\(duration)s")

        transcriptTasks[messageId] = Task { [weak self] in
            guard let self else { return }
            do {
                await VoiceTranscriber.logEnvironmentSummary()
                let locale = try await self.resolveTranscriptLocale()

                if await !VoiceTranscriber.isReady(locale) {
                    guard allowDownload else {
                        vtLog("run: not ready -> offering download")
                        await MainActor.run { self.setTranscript(messageId, .needsDownload(locale)) }
                        return
                    }
                    await MainActor.run { self.setTranscript(messageId, .downloading(fraction: 0, elapsed: 0)) }
                    // Already hopped to the main actor by downloadAssets.
                    try await VoiceTranscriber.shared.downloadAssets(for: locale) { fraction, elapsed in
                        self.setTranscript(messageId, .downloading(fraction: fraction, elapsed: elapsed))
                    }
                    await MainActor.run { self.setTranscript(messageId, .running) }
                }

                let text = try await VoiceTranscriber.shared.transcribe(
                    audio: audio, duration: duration, locale: locale)
                try Task.checkCancellation()
                vtLog("run: done, \(text.count) chars")
                await MainActor.run {
                    self.setTranscript(messageId, text.isEmpty ? .empty : .done(text))
                    self.transcriptTasks[messageId] = nil
                }
            } catch is CancellationError {
                vtLog("run: cancelled")
                // Left the room, or the language changed under us: leave the state alone.
            } catch VoiceTranscriptionError.modelNotInstalled(let locale) {
                vtLog("run: modelNotInstalled -> back to download prompt")
                // The engine's assets turned out to be missing after all: offer the download
                // instead of leaving the user at an error they can do nothing about.
                await MainActor.run {
                    self.setTranscript(messageId, .needsDownload(locale))
                    self.transcriptTasks[messageId] = nil
                }
            } catch {
                vtLog("run: FAILED \(vtDescribe(error))")
                await MainActor.run {
                    self.setTranscript(messageId, .failed(error.localizedDescription))
                    self.transcriptTasks[messageId] = nil
                }
            }
        }
    }
}
