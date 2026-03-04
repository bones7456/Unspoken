//
//  UnspokenWatchApp.swift
//  UnspokenWatch
//

import SwiftUI

#if os(watchOS)

@main
struct UnspokenWatchApp: App {
    @StateObject private var hrManager = HeartRateManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(hrManager)
        }
    }
}

#endif // os(watchOS)
