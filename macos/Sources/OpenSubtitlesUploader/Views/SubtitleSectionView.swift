import SwiftUI

struct SubtitleSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Subtitle file")).font(.headline)
                TextField(L("Drop a subtitle file or select one"), text: .constant(state.subtitle.path?.path ?? ""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(state.highlightMissingSubtitle ? Color.red : Color.clear))
                    .animation(.easeInOut, value: state.highlightMissingSubtitle)
                Button(L("Choose…")) { state.browse(.subtitle) }
                Button {
                    state.reset(.subtitle)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("Reset"))
                .disabled(state.subtitle.path == nil)
                .accessibilityLabel(L("Remove subtitle"))
            }

            HStack(spacing: 24) {
                Toggle(isOn: $state.subtitle.hearingImpaired) {
                    Label(L("Hearing impaired"), systemImage: "ear")
                }
                .help(L("The subtitle file contains descriptions of sounds and/or dialogues, meant for hearing impaired people"))
                Toggle(isOn: $state.subtitle.autoTranslated) {
                    Label(L("Auto-translated"), systemImage: "cpu")
                }
                .help(L("The subtitles were translated automatically by a machine"))
                Toggle(isOn: $state.subtitle.foreignPartsOnly) {
                    Label(L("Foreign parts only"), systemImage: "flag")
                }
                .help(L("The subtitles only translate non-native parts of the script, for example elvish and orkish in the Lord of the Rings"))
                Spacer()
            }
            .toggleStyle(.checkbox)

            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    MetaRow(label: L("File name"), required: true) { ReadOnlyField(text: state.subtitle.fileName) }
                    MetaRow(label: L("MD5 Hash"), required: true) { ReadOnlyField(text: state.subtitle.md5) }
                }
                .frame(maxWidth: .infinity)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    MetaRow(label: L("Language"), lock: .language) {
                        HStack(spacing: 6) {
                            Picker("", selection: $state.subtitle.languageCode) {
                                Text(L("None")).tag("")
                                ForEach(OSLanguages.all) { lang in
                                    Text(lang.displayName).tag(lang.code)
                                }
                            }
                            .labelsHidden()
                            .disabled(state.locks.contains(.language))
                            IconActionButton(systemImage: "wand.and.stars", help: L("Auto-detect the language"), busy: state.isDetectingLanguage) {
                                state.detectSubtitleLanguage()
                            }
                            .disabled(state.locks.contains(.language))
                        }
                    }
                    MetaRow(label: L("Translator"), lock: .translator) {
                        TextField("", text: $state.subtitle.translator)
                            .textFieldStyle(.roundedBorder)
                            .disabled(state.locks.contains(.translator))
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    HStack(spacing: 4) {
                        Text(L("Comment"))
                        LockButton(field: .comment)
                    }
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .gridColumnAlignment(.trailing)
                    TextEditor(text: $state.subtitle.comment)
                        .font(.body)
                        .frame(minHeight: 48, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .disabled(state.locks.contains(.comment))
                        .opacity(state.locks.contains(.comment) ? 0.6 : 1)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .sectionHighlight(state.dragHighlight.contains(.subtitle))
        .sectionHighlight(state.highlightMissingSubtitle, color: .red)
        .overlay(alignment: .bottom) {
            if state.current.isEmpty && !state.showsQueue {
                Text(L("Drop a video and a subtitle file anywhere in this window, or use the Choose… buttons."))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, -28)
            }
        }
        .onChange(of: state.highlightMissingSubtitle) { _, on in
            if on {
                Task {
                    try? await Task.sleep(for: .seconds(1.75))
                    state.highlightMissingSubtitle = false
                }
            }
        }
    }
}
