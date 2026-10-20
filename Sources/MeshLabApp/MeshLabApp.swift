import SwiftUI

@main
struct MeshLabApplication: App {
    @StateObject private var model = WorkbenchModel()

    var body: some Scene {
        WindowGroup {
            WorkbenchView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
    }
}
