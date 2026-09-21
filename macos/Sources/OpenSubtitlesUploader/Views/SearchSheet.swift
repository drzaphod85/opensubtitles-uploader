import SwiftUI

struct SearchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: SearchResult.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 12) {
            HStack {
                TextField(L("Enter a title"), text: $state.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit(search)
                Button(action: search) {
                    if state.isSearching {
                        ProgressView().controlSize(.small).frame(width: 16)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .help(L("Search"))
                .disabled(state.isSearching || state.searchQuery.isEmpty)
            }

            List(state.searchResults, selection: $selection) { result in
                Text(result.title)
                    .tag(result.id)
                    .onTapGesture(count: 2) { state.selectSearchResult(result) }
            }
            .frame(minHeight: 220)
            .overlay {
                if !APIKeys.hasTMDB {
                    ContentUnavailableView {
                        Label(L("Search needs a TMDB API key"), systemImage: "key.slash")
                    } description: {
                        Text(L("Add your own free TMDB API key in Settings to enable the title search and the backdrop image."))
                    } actions: {
                        SettingsLink { Text(L("Open Settings…")) }
                    }
                } else if state.searchPerformed && state.searchResults.isEmpty && !state.isSearching {
                    ContentUnavailableView(L("Not found"), systemImage: "film")
                }
            }

            HStack {
                Text(L("Search on IMDB directly")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("OK")) {
                    if let selected = state.searchResults.first(where: { $0.id == selection }) {
                        state.selectSearchResult(selected)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
        .onAppear { searchFocused = true }
        .onChange(of: state.searchResults) { _, results in
            selection = results.first?.id
        }
    }

    private func search() {
        selection = nil
        state.runSearch()
    }
}
