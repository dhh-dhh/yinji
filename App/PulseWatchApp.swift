import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct PulseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SessionModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { ConnectivityStore.shared.requestSync() }
                }
        }
    }
}

// Keep WatchConnectivity refresh tasks alive until queued inbound content is handled.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private var tasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var observations: [NSKeyValueObservation] = []
    override init() {
        super.init()
        let session = WCSession.default
        observations = [
            session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.completeIfReady() }
            },
            session.observe(\.activationState, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.completeIfReady() }
            }
        ]
    }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                tasks.append(connectivityTask)
                _ = ConnectivityStore.shared
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
        completeIfReady()
    }
    private func completeIfReady() {
        guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
        tasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        tasks.removeAll()
    }
}
