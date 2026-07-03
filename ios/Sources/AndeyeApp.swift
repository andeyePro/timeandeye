import SwiftUI
import AndeyeTTPhone

@main
struct AndeyeApp: App {
    @StateObject private var controller = PhoneController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NowView(controller: controller)
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep the live slice's crash checkpoint fresh at every
            // foreground/background transition — no timers needed.
            if phase == .active || phase == .background {
                controller.appLifecycleTick()
            }
        }
    }
}
