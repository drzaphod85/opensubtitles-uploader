import SwiftUI
import UniformTypeIdentifiers

/// A labelled row in the metadata grid, mirroring the original "metaitem" layout.
struct MetaRow<Content: View>: View {
    let label: String
    var required = false
    var lock: LockField? = nil
    @ViewBuilder var content: Content
    @Environment(AppState.self) private var state

    var body: some View {
        GridRow {
            HStack(spacing: 4) {
                Text(label)
                if required {
                    Text("*").foregroundStyle(.red).help(L("Metadata"))
                }
                if let lock {
                    LockButton(field: lock)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .foregroundStyle(.secondary)
            .font(.callout)
            .gridColumnAlignment(.trailing)
            content
        }
    }
}

struct LockButton: View {
    let field: LockField
    @Environment(AppState.self) private var state

    var body: some View {
        let locked = state.locks.contains(field)
        Button {
            state.toggleLock(field)
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .foregroundStyle(locked ? Color.accentColor : Color.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .help(locked ? L("Locked: value is kept between sessions") : L("Unlocked: click to keep this value between sessions"))
        .accessibilityLabel(L("Save between sessions"))
    }
}

/// Read-only value field that still allows selecting and copying.
struct ReadOnlyField: View {
    let text: String
    var body: some View {
        TextField("", text: .constant(text))
            .textFieldStyle(.roundedBorder)
            .disabled(text.isEmpty)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

/// Small button showing a spinner while busy.
struct IconActionButton: View {
    let systemImage: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy {
                ProgressView().controlSize(.mini).frame(width: 16, height: 16)
            } else {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(busy)
    }
}

/// Top-right sliding notification (the "snack" of the original app).
struct SnackView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .shadow(radius: 6, y: 2)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Handles files dragged from the Finder over the whole window and highlights the matching section.
struct FileDropDelegate: DropDelegate {
    let state: AppState

    private func loadURLs(_ info: DropInfo, completion: @escaping ([URL]) -> Void) {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { completion([]); return }
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        state.isDragTargeted = true
        loadURLs(info) { urls in
            state.dragHighlight = Set(urls.compactMap(FileTypes.kind(of:)))
        }
    }

    func dropExited(info: DropInfo) {
        state.isDragTargeted = false
        state.dragHighlight = []
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        loadURLs(info) { urls in state.handleDropped(urls) }
        return true
    }
}

extension View {
    /// Highlights a section with the accent colour, e.g. while a matching file is dragged over the window.
    func sectionHighlight(_ active: Bool, color: Color = .accentColor) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(active ? color : Color.clear, lineWidth: 2)
                .animation(.easeInOut(duration: 0.15), value: active)
        )
    }
}
