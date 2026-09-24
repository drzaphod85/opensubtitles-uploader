import SwiftUI

/// The upload queue table shown above the detail form when more than one item is loaded.
struct QueueView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Table(state.items, selection: Binding(get: { state.selectedItemID }, set: { state.select($0) })) {
            TableColumn("") { item in
                Image(systemName: item.statusSymbol)
                    .foregroundStyle(color(for: item))
                    .symbolEffect(.pulse, isActive: item.status.isBusy)
                    .help(item.statusText)
            }
            .width(22)
            TableColumn(L("Subtitle")) { item in
                Text(item.subtitle.fileName.isEmpty ? "—" : item.subtitle.fileName)
                    .foregroundStyle(item.subtitle.fileName.isEmpty ? .secondary : .primary)
            }
            TableColumn(L("Video")) { item in
                Text(item.video.fileName.isEmpty ? "—" : item.video.fileName)
                    .foregroundStyle(item.video.fileName.isEmpty ? .secondary : .primary)
            }
            TableColumn(L("Language")) { item in
                Text(OSLanguages.language(code: item.subtitle.languageCode)?.name ?? "—")
            }
            .width(min: 80, ideal: 110)
            TableColumn(L("IMDB id")) { item in
                Text(item.video.detectedTitle.isEmpty ? item.video.imdbId : item.video.detectedTitle)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 200)
            TableColumn(L("Status")) { item in
                Text(item.statusText).foregroundStyle(color(for: item)).lineLimit(1)
            }
            .width(min: 90, ideal: 150)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let selected = state.items.filter { ids.contains($0.id) }
            if let one = selected.first, selected.count == 1 {
                Button(L("Check")) { state.check(one) }
                    .disabled(one.subtitle.path == nil || one.status.isBusy || one.status == .uploaded)
                if let url = one.uploadedURL ?? one.existingSubtitleURL {
                    Button(L("Open on OpenSubtitles")) { state.openExternal(url) }
                }
                if let file = one.subtitle.path ?? one.video.path {
                    Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Divider()
            }
            Button(L("Remove from queue")) { state.removeItems(ids) }
                .disabled(selected.allSatisfy { $0.status.isBusy })
        } primaryAction: { ids in
            if let id = ids.first { state.select(id) }
        }
        .onDeleteCommand {
            if let id = state.selectedItemID { state.removeItems([id]) }
        }
    }

    private func color(for item: QueueItem) -> Color {
        switch item.status {
        case .uploaded: return .green
        case .exists: return .orange
        case .failed: return .red
        case .checking, .uploading: return .accentColor
        default: return .secondary
        }
    }
}
