import SwiftUI

/// The "Upload History" window: everything uploaded from this Mac.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @ViewState private var selection = Set<HistoryEntry.ID>()
    @ViewState private var confirmClear = false

    private var history: UploadHistory { state.history }

    var body: some View {
        VStack(spacing: 0) {
            Table(history.entries, selection: $selection) {
                TableColumn(L("Date")) { entry in
                    Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                }
                .width(min: 120, ideal: 140)
                TableColumn(L("Subtitle"), value: \.subtitleName)
                TableColumn(L("Video")) { entry in Text(entry.videoName ?? "—") }
                TableColumn(L("Language")) { entry in
                    Text(entry.languageCode.flatMap { OSLanguages.language(code: $0)?.name } ?? "—")
                }
                .width(min: 80, ideal: 110)
                TableColumn(L("IMDB id")) { entry in Text(entry.title ?? entry.imdbId ?? "—").lineLimit(1) }
                TableColumn(L("Result")) { entry in
                    Label(entry.result == .uploaded ? L("Uploaded") : L("Already in database"),
                          systemImage: entry.result == .uploaded ? "checkmark.circle.fill" : "quote.opening")
                        .foregroundStyle(entry.result == .uploaded ? .green : .orange)
                }
                .width(min: 120, ideal: 170)
            }
            .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                if ids.count == 1, let entry = history.entries.first(where: { ids.contains($0.id) }), let url = entry.url {
                    Button(L("Open on OpenSubtitles")) { state.openExternal(url) }
                }
                Button(L("Remove")) { history.remove(ids: ids) }
            } primaryAction: { ids in
                if let entry = history.entries.first(where: { ids.contains($0.id) }), let url = entry.url { state.openExternal(url) }
            }
            .overlay {
                if history.entries.isEmpty {
                    ContentUnavailableView(L("No uploads yet."), systemImage: "clock.arrow.circlepath")
                }
            }

            Divider()
            HStack {
                Text(L("%@ uploads", String(history.entries.count))).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button(L("Clear History")) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 320)
        .confirmationDialog(L("Clear History"), isPresented: $confirmClear) {
            Button(L("Clear History"), role: .destructive) { history.clear() }
        } message: {
            Text(L("This removes the list in this app only; nothing is deleted on OpenSubtitles."))
        }
        .navigationTitle(L("Upload History"))
    }
}
