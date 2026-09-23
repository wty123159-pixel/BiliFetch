import SwiftUI

@MainActor
final class BiliFetchAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DownloadViewModel?
    weak var startupCapture: WeChatCaptureController?
    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the notice must not leave an unacknowledged app running.
        model == nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateCancel }
        if let model, model.isDownloading && !model.isPaused { model.togglePause() }
        guard let capture = model?.weChatCapture ?? startupCapture,
              capture.isRunning else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            do {
                try await capture.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                let alert = NSAlert()
                alert.messageText = "网络设置尚未恢复"
                alert.informativeText = error.localizedDescription + "\n请在视频号面板关闭捕获后再退出。"
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

@MainActor
private final class StartupSession: ObservableObject {
    @Published private(set) var model: DownloadViewModel?
    private(set) var updater: MacAppUpdater?
    let capture = WeChatCaptureController()

    func acknowledge() {
        guard model == nil else { return }
        updater = MacAppUpdater()
        model = DownloadViewModel(capture: capture)
    }
}

@main
struct BiliFetchApp: App {
    @NSApplicationDelegateAdaptor(BiliFetchAppDelegate.self) private var appDelegate
    @StateObject private var session = StartupSession()

    var body: some Scene {
        WindowGroup("记住你宇哥") {
            Group {
                if let model = session.model, let updater = session.updater {
                    ContentView(model: model, updater: updater)
                } else {
                    StartupNoticeView {
                        session.acknowledge()
                        appDelegate.model = session.model
                    }
                }
            }
            .onAppear {
                appDelegate.startupCapture = session.capture
                // Restore a prior interrupted proxy even before acknowledgement;
                // download recovery and update checks wait for the button.
                session.capture.recoverIfNeeded()
            }
            .frame(minWidth: 760, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 400)
    }
}
