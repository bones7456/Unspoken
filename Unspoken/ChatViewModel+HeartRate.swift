//
//  ChatViewModel+HeartRate.swift
//  Unspoken
//

import HealthKit
import UIKit
import WatchConnectivity

extension ChatViewModel {

    // MARK: - WatchConnectivity

    func setupWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        let adapter = WCAdapter { [weak self] bpm in
            DispatchQueue.main.async { self?.currentBPM = bpm }
        }
        self.wcAdapter = adapter
        WCSession.default.delegate = adapter
        WCSession.default.activate()
    }

    // MARK: - Background Task

    func beginHeartRateBackgroundTaskIfNeeded() {
        guard isHeartRateMode, heartRateBackgroundTask == .invalid else { return }
        heartRateBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HeartRateTransmission") { [weak self] in
            self?.stopHeartRateMode(notifyPeer: true)
            self?.endHeartRateBackgroundTask()
        }
    }

    func endHeartRateBackgroundTask() {
        guard heartRateBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(heartRateBackgroundTask)
        heartRateBackgroundTask = .invalid
    }

    // MARK: - Heart Rate Mode

    var canUseHeartRateMode: Bool {
        peerPublicKey != nil && peerIsOnline
    }

    func startHeartRateMode() {
        guard HKHealthStore.isHealthDataAvailable() else {
            heartRateModeError = "Health data is not available on this device."
            return
        }
        let store = HKHealthStore()
        healthStore = store
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        store.requestAuthorization(toShare: nil, read: [heartRateType]) { [weak self] success, _ in
            guard let self else { return }
            guard success else {
                DispatchQueue.main.async {
                    self.heartRateModeError = "Please allow Health access in Settings to share your heart rate."
                }
                return
            }
            let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
                guard error == nil else { completionHandler(); return }
                self?.fetchLatestHeartRate(store: store)
                completionHandler()
            }
            self.hkObserverQuery = query
            store.execute(query)
            self.fetchLatestHeartRate(store: store)

            DispatchQueue.main.async {
                self.isHeartRateMode = true
                if WCSession.isSupported() && WCSession.default.isReachable {
                    WCSession.default.sendMessage(["action": "start_heart_rate"], replyHandler: nil, errorHandler: nil)
                } else if WCSession.isSupported() && WCSession.default.isPaired {
                    self.heartRateModeError = "Please open the Unspoken app on your Apple Watch for real-time heart rate."
                }
                self.heartRateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    guard let self, let bpm = self.currentBPM else { return }
                    self.sendHeartRate(bpm: bpm)
                }
            }
        }
    }

    func stopHeartRateMode(notifyPeer: Bool = true) {
        guard isHeartRateMode else { return }
        isHeartRateMode = false
        heartRateTimer?.invalidate()
        heartRateTimer = nil
        endHeartRateBackgroundTask()
        currentBPM = nil
        if let query = hkObserverQuery {
            healthStore?.stop(query)
            hkObserverQuery = nil
        }
        if notifyPeer { sendHeartRate(bpm: -1) }
        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(["action": "stop_heart_rate"], replyHandler: nil, errorHandler: nil)
        }
    }

    func stopPeerHeartRate() {
        hapticLoopActive = false
        peerBPM = nil
    }

    func sendHeartRate(bpm: Int) {
        guard let (encryptedAESKey, encryptedContent) = encryptMessage("\(bpm)") else { return }
        sendJSON([
            "action": "heart_rate",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent
        ])
    }

    func handleReceivedHeartRate(bpm: Int) {
        if bpm == -1 { stopPeerHeartRate(); return }
        peerBPM = bpm
        guard !hapticLoopActive else { return }
        hapticLoopActive = true
        let heavy  = UIImpactFeedbackGenerator(style: .heavy)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        heavy.prepare()
        medium.prepare()
        beatLoop(heavy: heavy, medium: medium)
    }

    // MARK: - Private helpers

    private func fetchLatestHeartRate(store: HKHealthStore) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = Int(sample.quantity.doubleValue(for: HKUnit(from: "count/min")))
            DispatchQueue.main.async { self?.currentBPM = bpm }
        }
        store.execute(query)
    }

    private func beatLoop(heavy: UIImpactFeedbackGenerator, medium: UIImpactFeedbackGenerator) {
        guard hapticLoopActive, let bpm = peerBPM else {
            hapticLoopActive = false
            return
        }
        let interval = 60.0 / Double(bpm)
        let gap = max(0.05, 0.5 - 0.0021 * Double(bpm))
        heavy.impactOccurred()
        peerLubTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            guard let self, self.hapticLoopActive else { return }
            medium.impactOccurred()
            self.peerDubTick += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - gap)) { [weak self] in
                self?.beatLoop(heavy: heavy, medium: medium)
            }
        }
    }
}
