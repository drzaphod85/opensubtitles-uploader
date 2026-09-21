import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 14) {
            VideoSectionView()
            SubtitleSectionView()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(state: state))
        .overlay(alignment: .topTrailing) {
            if let snack = state.snack {
                SnackView(message: snack)
            }
        }
        .overlay {
            if state.isUploading {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L("Uploading…")).font(.headline)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.snack)
        .animation(.easeInOut(duration: 0.2), value: state.isUploading)
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.showLoginSheet) { LoginSheet() }
        .sheet(isPresented: $state.showSearchSheet) { SearchSheet() }
        .alert(state.alert?.title ?? "", isPresented: alertPresented, presenting: state.alert) { alert in
            ForEach(alert.buttons) { button in
                Button(button.title, role: button.role == .cancel ? .cancel : (button.role == .destructive ? .destructive : nil), action: button.action)
            }
        } message: { alert in
            Text(alert.message)
        }
        .navigationTitle("OpenSubtitles Uploader")
        .navigationSubtitle(state.video.detectedTitle)
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.verifyAndUpload()
            } label: {
                Label(L("Upload"), systemImage: uploadIcon)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(uploadTint)
            .disabled(state.isUploading)
            .help(L("Upload") + " (⌘↩)")
            .keyboardShortcut(.return, modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            accountItem
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label(L("Settings"), systemImage: "gearshape")
            }
            .help(L("Settings"))
        }
    }

    private var uploadIcon: String {
        switch state.uploadButtonState {
        case .idle: return "icloud.and.arrow.up"
        case .success: return "checkmark.icloud"
        case .partial: return "quote.opening"
        case .failure: return "xmark.icloud"
        }
    }

    private var uploadTint: Color {
        switch state.uploadButtonState {
        case .idle: return .accentColor
        case .success: return .green
        case .partial: return .orange
        case .failure: return .red
        }
    }

    @ViewBuilder
    private var accountItem: some View {
        if state.isLoggedIn {
            Menu {
                if let rank = state.userRank, !rank.isEmpty {
                    Text(rank.uppercased())
                }
                Button(L("Open Profile")) { state.openProfile() }
                    .disabled(state.userId == nil)
                Divider()
                Button(L("Sign Out")) { state.logout() }
            } label: {
                Label(state.username, systemImage: "person.crop.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .help(L("Logged in as %@", state.username))
        } else {
            Button {
                state.showLoginSheet = true
            } label: {
                Label(L("Sign In…"), systemImage: "person.crop.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help(L("Log in"))
        }
    }
}
