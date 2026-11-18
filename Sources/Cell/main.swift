import SwiftUI
import CellUI

struct CellApp: App {
    @NSApplicationDelegateAdaptor(CellAppDelegate.self) private var appDelegate

    var body: some Scene {
        CellScenes()
    }
}

CellApp.main()
