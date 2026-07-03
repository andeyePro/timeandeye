import SwiftUI
import andeyeTTMac
import andeyeTTUI

/// Community flavour: OpenProject + standalone, everything in andeyeTTUI.
/// The Pro flavour (private repo) is the same three lines plus paid-backend
/// registration before the scenes are built.
@main
struct AndeyeCommunityApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        AndeyeScenes.body(controller: controller)
    }
}
