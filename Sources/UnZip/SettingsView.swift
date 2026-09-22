import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, folders, explorer, sidebar, playback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .folders: "Folder Images"
        case .explorer: "Explorer"
        case .sidebar: "Sidebar"
        case .playback: "Playback"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .folders: "folder.badge.gearshape"
        case .explorer: "rectangle.grid.2x2"
        case .sidebar: "sidebar.left"
        case .playback: "play.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ViewState private var category: SettingsCategory = .appearance

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

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsCategory.allCases) { item in
                        Button {
                            category = item
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(category == item ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 168)
                .padding(.leading, 16)
                .padding(.trailing, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch category {
                        case .appearance: appearancePage
                        case .folders: foldersPage
                        case .explorer: explorerPage
                        case .sidebar: sidebarPage
                        case .playback: playbackPage
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 680, height: 560)
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

    private var appearancePage: some View {
        group("Theme", "Colors for the window and accent.") {
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
    }

    private var foldersPage: some View {
        group("Folder covers", "Default look for folders that do not have their own image.") {
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
    }

    private var explorerPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Views", "Choose which folder views appear on the tab bar.") {
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

            group("Sort and filter", "Defaults for listing files.") {
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
        }
    }

    private var sidebarPage: some View {
        group("Sidebar sections", "Turn sections on or off. The current folder always stays at the top.") {
            Toggle("Favorites (Home, Desktop, Downloads…)", isOn: Binding(
                get: { appearance.showSidebarFavorites },
                set: { appearance.showSidebarFavorites = $0 }
            ))
            Toggle("Devices (USB and external disks)", isOn: Binding(
                get: { appearance.showSidebarDevices },
                set: { appearance.showSidebarDevices = $0 }
            ))
            Toggle("Archives", isOn: Binding(
                get: { appearance.showSidebarArchives },
                set: { appearance.showSidebarArchives = $0 }
            ))
            Toggle("Servers", isOn: Binding(
                get: { appearance.showSidebarServers },
                set: { appearance.showSidebarServers = $0 }
            ))
            Toggle("Recent", isOn: Binding(
                get: { appearance.showSidebarRecents },
                set: { appearance.showSidebarRecents = $0 }
            ))
            if !state.recents.isEmpty {
                Button("Clear All Recent") {
                    state.clearRecents()
                }
            }
        }
    }

    private var playbackPage: some View {
        group("Music bar", "Shown when a folder has audio. Click it to open the full player.") {
            HStack {
                Text("Height")
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
            Text("Shuffle, auto-next, and loop live on the music player.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func group<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
