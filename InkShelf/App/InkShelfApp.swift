import SwiftUI

@main
struct InkShelfApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryStore()
    @StateObject private var readAloud = ReadAloudService()

    init() {
        ReaderFontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                BookshelfView()
                PersistentReadAloudOverlay(readAloud: readAloud)
            }
                .environmentObject(library)
                .environmentObject(readAloud)
                .preferredColorScheme(.light)
                .onAppear {
                    readAloud.applicationActivityChanged(isActive: scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    readAloud.applicationActivityChanged(isActive: phase == .active)
                }
                .onChange(of: readAloud.currentPageLocation) { _, location in
                    guard let location, let bookID = readAloud.bookContext?.id else { return }
                    library.updateProgress(
                        bookID: bookID,
                        chapter: location.chapterIndex,
                        page: location.pageIndex
                    )
                }
        }
    }
}
