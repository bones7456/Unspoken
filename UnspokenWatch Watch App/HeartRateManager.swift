//
//  HeartRateManager.swift
//  UnspokenWatch
//

import Foundation
import HealthKit
import WatchConnectivity

#if os(watchOS)

class HeartRateManager: NSObject, ObservableObject {
    @Published var currentBPM: Int?
    @Published var isSessionActive = false

    private let healthStore = HKHealthStore()
    private var anchoredQuery: HKAnchoredObjectQuery?
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        healthStore.requestAuthorization(toShare: [], read: [hrType]) { _, _ in }
    }

    func startSession() {
        guard !isSessionActive else { return }
        // Always start in query-only mode first — safe, never interferes with existing workouts.
        // If another app's workout is active, the sensor is already running and we'll get
        // near-real-time samples via the anchored query within a few seconds.
        // If no workout is active, the sensor is idle and we'll get no data.
        // After 10s with no data, escalate to starting our own HKWorkoutSession.
        startQueryOnlyMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.isSessionActive, self.currentBPM == nil, self.workoutSession == nil else { return }
            if let query = self.anchoredQuery {
                self.healthStore.stop(query)
                self.anchoredQuery = nil
            }
            self.startWorkoutSessionMode()
        }
    }

    private func startQueryOnlyMode() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil)
        let query = HKAnchoredObjectQuery(type: hrType, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            self?.handleSamples(samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handleSamples(samples)
        }
        healthStore.execute(query)
        self.anchoredQuery = query
        DispatchQueue.main.async { self.isSessionActive = true }
    }

    private func startWorkoutSessionMode() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        guard let session = try? HKWorkoutSession(healthStore: healthStore, configuration: config) else { return }
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
        session.delegate = self
        builder.delegate = self
        self.workoutSession = session
        self.builder = builder
        let now = Date()
        session.startActivity(with: now)
        builder.beginCollection(withStart: now) { _, _ in }
        DispatchQueue.main.async { self.isSessionActive = true }
    }

    func stopSession() {
        guard isSessionActive else { return }
        if let query = anchoredQuery {
            healthStore.stop(query)
            self.anchoredQuery = nil
        }
        if workoutSession != nil {
            workoutSession?.end()
            builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
                self?.builder?.discardWorkout()
            }
            workoutSession = nil
            builder = nil
        }
        DispatchQueue.main.async {
            self.isSessionActive = false
            self.currentBPM = nil
        }
    }

    private func handleSamples(_ samples: [HKSample]?) {
        guard let sample = samples?.last as? HKQuantitySample else { return }
        let bpm = Int(sample.quantity.doubleValue(for: HKUnit(from: "count/min")))
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["bpm": bpm], replyHandler: nil, errorHandler: nil)
        }
        DispatchQueue.main.async { self.currentBPM = bpm }
    }
}

// MARK: - HKWorkoutSessionDelegate
extension HeartRateManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout session failed: \(error)")
        DispatchQueue.main.async { self.isSessionActive = false }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension HeartRateManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType.quantityType(forIdentifier: .heartRate)!),
              let stats = workoutBuilder.statistics(for: HKQuantityType.quantityType(forIdentifier: .heartRate)!),
              let qty = stats.mostRecentQuantity() else { return }
        let bpm = Int(qty.doubleValue(for: HKUnit(from: "count/min")))
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["bpm": bpm], replyHandler: nil, errorHandler: nil)
        }
        DispatchQueue.main.async { self.currentBPM = bpm }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - WCSessionDelegate
extension HeartRateManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        DispatchQueue.main.async {
            switch action {
            case "start_heart_rate": self.startSession()
            case "stop_heart_rate":  self.stopSession()
            default: break
            }
        }
    }
}

#endif // os(watchOS)
