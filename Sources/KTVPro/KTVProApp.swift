import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: SessionModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        DispatchQueue.main.async {
            model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct KTakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SessionModel()
    var body: some Scene {
        Window("KTake", id: "studio") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .saveItem) {
                Button("打开录音文件夹") { model.revealTakes() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
