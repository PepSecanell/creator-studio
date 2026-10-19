import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(model.title) {
            Group {
                switch model.state {
                case .ready(let controller):
                    ContentView()
                        .environmentObject(controller)
                        .tint(controller.brand.accentColor)
                        .task {
                            QuitGuard.finishingCount = { controller.finishingCount }
                            await controller.checkPermissionAndLoadDisplays()
                        }
                case .needsSetup(let message):
                    SetupNeededView(message: message)
                }
            }
            // Must match ContentView's own width (400), or the content is cut at both edges.
            .frame(width: 400)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Reads the shared config once at launch. Without it the app cannot know where
/// to write takes, so it shows the setup message instead of the recorder.
@MainActor
final class AppModel: ObservableObject {
    enum State {
        case ready(RecordingController)
        case needsSetup(String)
    }

    let state: State
    let title: String

    init() {
        switch StudioConfig.load() {
        case .success(let config):
            let workspace = Workspace(config: config)
            let brand = BrandInfo.load(workspace: workspace)
            state = .ready(RecordingController(workspace: workspace, brand: brand))
            title = brand.recorderTitle
        case .failure(let error):
            switch error {
            case .missing(let url):
                state = .needsSetup("No workspace found. Expected the config file at \(url.path).")
            case .unreadable(let url):
                state = .needsSetup("The config file at \(url.path) could not be read.")
            }
            title = BrandInfo.fallback.recorderTitle
        }
    }
}

/// Shown when `./studio setup` has not been run yet.
struct SetupNeededView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Run ./studio setup first", systemImage: "wrench.and.screwdriver")
                .font(.system(size: 15, weight: .semibold))
            Text("This recorder saves its takes into your creator-studio workspace, and it has not been set up yet.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text("Open a terminal in the creator-studio folder, run ./studio setup, then open this app again.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Takes finish in the background, so quitting right after a take could throw one away.
final class QuitGuard: NSObject, NSApplicationDelegate {
    @MainActor static var finishingCount: () -> Int = { 0 }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = Self.finishingCount()
        guard n > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = n == 1 ? "A take is still being finished" : "\(n) takes are still being finished"
        alert.informativeText = "If you quit now their composite.mov files will not be written. The raw files stay in the take folder."
        alert.addButton(withTitle: "Keep open")
        alert.addButton(withTitle: "Quit anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
