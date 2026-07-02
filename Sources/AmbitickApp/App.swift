import SwiftUI
import AmbitickMac
import AmbitickUI

/// Community flavour: OpenProject + standalone, everything in AmbitickUI.
/// The Pro flavour (private repo) is the same three lines plus paid-backend
/// registration before the scenes are built.
@main
struct AmbitickCommunityApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        AmbitickScenes.body(controller: controller)
    }
}
