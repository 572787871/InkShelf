import SwiftUI

struct BookInfoView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State private var title = ""
    @State private var author = ""

    var body: some View {
        Form {
            if let book = library.book(id: bookID) {
                Section {
                    HStack { Spacer(); BookCoverView(book: book).frame(width: 125); Spacer() }.listRowBackground(Color.clear)
                }
                Section("书籍信息") {
                    TextField("书名", text: $title)
                    TextField("作者", text: $author)
                    LabeledContent("格式", value: book.format.rawValue)
                    LabeledContent("章节", value: "\(book.displayChapterCount)")
                    LabeledContent("字数", value: book.content.count.formatted())
                }
                Section { Button("保存修改") { library.updateMetadata(bookID: bookID, title: title, author: author); dismiss() } }
            }
        }
        .navigationTitle("书籍信息")
        .onAppear { if let book = library.book(id: bookID) { title = book.title; author = book.author } }
    }
}
