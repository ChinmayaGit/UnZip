import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var appearance: AppearancePreferences { state.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Theme") {
                        Picker("Theme", selection: Binding(
                            get: { appearance.theme },
                            set: { appearance.theme = $0 }
                        )) {
                            ForEach(AppTheme.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    section("Folder Image") {
                        Text("Default cover for folders that do not have their own image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        CoverStyleForm(
                            style: Binding(
                                get: { appearance.globalCover },
                                set: { appearance.globalCover = $0 }
                            ),
                            appearance: appearance
                        )
                        Picker("Default folder icon", selection: Binding(
                            get: { appearance.defaultFolderSymbol },
                            set: { appearance.defaultFolderSymbol = $0 }
                        )) {
                            ForEach(AppearancePreferences.folderSymbols, id: \.self) { symbol in
                                Label(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ").capitalized, systemImage: symbol).tag(symbol)
                            }
                        }
                    }

                    section("Views") {
                        Text("The first three stay on the tab bar by default. Turn on more views here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(BrowserLayout.allCases) { layout in
                            Toggle(isOn: Binding(
                                get: { appearance.isLayoutEnabled(layout) },
                                set: { _ in
                                    appearance.toggleLayout(layout)
                                    if !appearance.isLayoutEnabled(state.browserLayout) {
                                        state.setLayout(appearance.visibleLayouts[0])
                                    }
                                }
                            )) {
                                Label(layout.title, systemImage: layout.systemImage)
                            }
                            .disabled(appearance.visibleLayouts.count == 1 && appearance.isLayoutEnabled(layout))
                        }
                        HStack {
                            Text("Icon scale")
                            Slider(
                                value: Binding(
                                    get: { appearance.iconScale },
                                    set: { appearance.iconScale = $0 }
                                ),
                                in: 0.6...2.0
                            )
                            Text(String(format: "%.0f%%", appearance.iconScale * 100))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    section("Sort & Filter") {
                        Picker("Default sort", selection: Binding(
                            get: { state.entrySort },
                            set: { state.setSort($0) }
                        )) {
                            ForEach(EntrySort.allCases) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                        Toggle("Folders first", isOn: Binding(
                            get: { appearance.foldersFirst },
                            set: { appearance.foldersFirst = $0 }
                        ))
                        Toggle("Show hidden files", isOn: Binding(
                            get: { appearance.showHidden },
                            set: {
                                appearance.showHidden = $0
                                state.fileBrowser.reload(showHidden: $0)
                            }
                        ))
                        Toggle("Show file extensions", isOn: Binding(
                            get: { appearance.showExtensions },
                            set: { appearance.showExtensions = $0 }
                        ))
                        Picker("Kind filter", selection: Binding(
                            get: { appearance.kindFilter },
                            set: { appearance.kindFilter = $0 }
                        )) {
                            ForEach(KindFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    }

                    section("Playback") {
                        Text("When a folder has several tracks, UnZip can shuffle, auto-play next, and loop like a music player. Click the music bar to open the full player in preview.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Music bar height")
                            Slider(
                                value: Binding(
                                    get: { appearance.musicBarHeight },
                                    set: { appearance.musicBarHeight = $0 }
                                ),
                                in: 64...140
                            )
                            Text("\(Int(appearance.musicBarHeight)) pt")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 540, height: 640)
        .onChange(of: appearance.globalCover) { _, _ in
            state.refreshCovers()
        }
        .onChange(of: appearance.defaultFolderSymbol) { _, _ in
            state.refreshCovers()
        }
        .onChange(of: appearance.theme) { _, _ in
            state.objectWillChange.send()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
