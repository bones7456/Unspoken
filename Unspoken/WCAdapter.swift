//
//  WCAdapter.swift
//  Unspoken
//

import WatchConnectivity

// NSObject wrapper required for WCSessionDelegate conformance.
// ChatViewModel cannot inherit NSObject (it inherits ObservableObject).
class WCAdapter: NSObject, WCSessionDelegate {
    private let onBPM: (Int) -> Void
    init(onBPM: @escaping (Int) -> Void) { self.onBPM = onBPM }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let bpm = message["bpm"] as? Int else { return }
        onBPM(bpm)
    }
}
