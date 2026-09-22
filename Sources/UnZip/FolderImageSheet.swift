import AppKit
import SwiftUI

struct FolderImageTarget: Identifiable {
    var url: URL
    var name: String
    var id: String { url.standardizedFileURL.path }
}

struct FolderImageSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var target: FolderImageTarget?

    @ViewState private var style = CoverStyle()
    @ViewState private var applyGlobally = false

    private var appearance: AppearancePreferences { state.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target == nil ? "Default Folder Image" : "Folder Image")
                .font(.title2.weight(.semibold))
            Text(target == nil
                 ? "Used for every folder that does not have its own cover."
                 : "“\(target!.name)” keeps the automatic first-image cover unless you change it.")
                .foregroundStyle(.secondary)

            Button {
                if let path = appearance.importCoverImage() {
                    style.mode = .custom
                    style.imagePath = path
                }
            } label: {
                Label("Pick Image from Anywhere…", systemImage: "photo.on.rectangle")
            }
            .help("Choose a picture from any folder on this Mac")

            CoverStyleForm(style: $style, appearance: appearance)

            if target != nil {
                Toggle("Also use as the default for all folders", isOn: $applyGlobally)
            }

            HStack {
                if target != nil {
                    Button("Reset This Folder") {
                        if let url = target?.url {
                            appearance.clearCover(for: url)
                            state.refreshCovers()
                        }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    appearance.setCover(style, for: target?.url, applyGlobally: applyGlobally || target == nil)
                    state.refreshCovers()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if let url = target?.url {
                style = appearance.coverStyle(for: url)
            } else {
                style = appearance.globalCover
            }
        }
    }
}

struct CoverStyleForm: View {
    @Binding var style: CoverStyle
    @ObservedObject var appearance: AppearancePreferences

    var body: some View {
        Picker("Image", selection: $style.mode) {
            ForEach(CoverMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        switch style.mode {
        case .auto:
            Text("The first picture in the folder is used as the cover. This is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            Text("Show the default folder icon instead of a picture.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .custom:
            HStack {
                Button("Pick Image…") {
                    if let path = appearance.importCoverImage() {
                        style.imagePath = path
                    }
                }
                if let path = style.imagePath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("PNG, JPEG, HEIC, WebP, ICO, ICNS…")
                        .foregroundStyle(.tertiary)
                }
            }
        case .symbol:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
                ForEach(AppearancePreferences.folderSymbols, id: \.self) { symbol in
                    Button {
                        style.symbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 32, height: 32)
                            .background(
                                style.resolvedSymbol == symbol
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Picker("Fit", selection: $style.fit) {
            ForEach(CoverFit.allCases) { fit in
                Text(fit.title).tag(fit)
            }
        }
        .pickerStyle(.segmented)
        Text(style.fit.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
