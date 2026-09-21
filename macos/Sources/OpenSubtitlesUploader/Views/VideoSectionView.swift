import SwiftUI

struct VideoSectionView: View {
    @Environment(AppState.self) private var state
    @FocusState private var imdbFocused: Bool
    @ViewState private var imdbValueOnFocus = ""

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Video file")).font(.headline)
                TextField(L("Drop a video file or select one"), text: .constant(state.video.path?.path ?? ""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button(L("Choose…")) { state.browse(.video) }
                Button {
                    state.reset(.video)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("Reset"))
                .disabled(state.video.path == nil)
                .accessibilityLabel(L("Remove video"))
            }

            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    MetaRow(label: L("File name"), required: true) { ReadOnlyField(text: state.video.fileName) }
                    MetaRow(label: L("OSDb Hash"), required: true) { ReadOnlyField(text: state.video.hash) }
                    MetaRow(label: L("Size") + " (" + L("bytes") + ")", required: true) { ReadOnlyField(text: state.video.byteSize) }
                    MetaRow(label: L("IMDB id"), lock: .imdbId) {
                        HStack(spacing: 6) {
                            TextField("tt0000000", text: $state.video.imdbId)
                                .textFieldStyle(.roundedBorder)
                                .disabled(state.locks.contains(.imdbId))
                                .focused($imdbFocused)
                                .onSubmit { imdbFocused = false }
                                .onChange(of: imdbFocused) { _, focused in
                                    if focused {
                                        imdbValueOnFocus = state.video.imdbId
                                    } else {
                                        state.imdbFieldCommitted(previous: imdbValueOnFocus)
                                    }
                                }
                            imdbStatusView
                            IconActionButton(systemImage: "magnifyingglass", help: L("Search on IMDB directly") + " (⌘F)", busy: state.isLookingUpImdb) {
                                state.openSearch()
                            }
                        }
                    }
                    MetaRow(label: L("High definition")) {
                        Toggle("", isOn: $state.video.highDefinition).labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    MetaRow(label: L("Movie AKA"), lock: .movieAka) {
                        TextField("", text: $state.video.movieAka)
                            .textFieldStyle(.roundedBorder)
                            .disabled(state.locks.contains(.movieAka))
                    }
                    MetaRow(label: L("Release name")) {
                        TextField("", text: $state.video.releaseName).textFieldStyle(.roundedBorder)
                    }
                    MetaRow(label: L("FPS")) {
                        TextField("", text: $state.video.fps).textFieldStyle(.roundedBorder)
                    }
                    MetaRow(label: L("Total time") + " (ms)") { ReadOnlyField(text: state.video.timeMs) }
                    MetaRow(label: L("Number of frames")) { ReadOnlyField(text: state.video.frames) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .sectionHighlight(state.dragHighlight.contains(.video))
        .overlay {
            if state.isAnalyzingVideo {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L("Analyzing video…")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.isAnalyzingVideo)
    }

    @ViewBuilder
    private var sectionBackground: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let url = state.video.backdropURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var imdbStatusView: some View {
        switch state.video.imdbStatus {
        case .none:
            EmptyView()
        case .verified(let title):
            Button { state.openImdb() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("IMDB: \(title)")
            .accessibilityLabel(L("Open in IMDb"))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(L("This IMDB id could not be checked, be careful with your upload"))
        }
    }
}
