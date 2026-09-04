import SwiftUI

@main
struct BiliFetchApp: App {
    @StateObject private var model = DownloadViewModel()
    @StateObject private var updater = MacAppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, updater: updater)
                .frame(minWidth: 760, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 400)
    }
}
