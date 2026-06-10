import AppKit
import SwiftUI
import FlockCore

@main
struct OpenFlockApp: App {
    @State private var model = FlockModel()

    init() {
        // Menu bar app: no Dock icon. (Proper .app bundle sets LSUIElement;
        // this covers `swift run` during development.)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            FlockPanel(model: model)
        } label: {
            Text(model.menuBarSummary)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
