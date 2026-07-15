import SwiftUI

@main
struct InkShelfApp: App {
    @StateObject private var library = LibraryStore()

    init() {
        ReaderFontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            BookshelfView()
                .environmentObject(library)
                .preferredColorScheme(.light)
        }
    }
}
