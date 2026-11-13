import SwiftUI

@main
struct BaginCamApp: App {
    init() { LogFile.shared.start() }      // v0.17.1: log ke file (tes tanpa kabel)
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
