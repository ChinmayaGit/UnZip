import AppKit
import SwiftUI

@MainActor
final class ImageGallery: ObservableObject {
    @Published var isPresented = false
    @Published var urls: [URL] = []
    @Published var index = 0
    @Published var image: NSImage?
    @Published var isLoading = false

    private var keyMonitor: Any?
    private var loadToken = UUID()

    var currentURL: URL? {
        urls.indices.contains(index) ? urls[index] : nil
    }

    var title: String {
        currentURL?.lastPathComponent ?? "Image"
    }

    var positionLabel: String {
        guard !urls.isEmpty else { return "" }
        return "\(index + 1) of \(urls.count)"
    }

    func open(url: URL, folderImages: [URL]) {
        var list = folderImages.map(\.standardizedFileURL)
        let current = url.standardizedFileURL
        if !list.contains(current) {
            list.append(current)
        }
        list.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        urls = list
        index = list.firstIndex(of: current) ?? 0
        isPresented = true
        installKeyMonitor()
        loadCurrent()
    }

    func close() {
        isPresented = false
        image = nil
        urls = []
        index = 0
        removeKeyMonitor()
    }

    func go(_ delta: Int) {
        guard urls.count > 1 else { return }
        index = (index + delta + urls.count) % urls.count
        loadCurrent()
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func loadCurrent() {
        guard let url = currentURL else {
            image = nil
            return
        }
        let token = UUID()
        loadToken = token
        isLoading = image == nil
        Task.detached {
            let loaded = NSImage(contentsOf: url)
            await MainActor.run {
                guard self.loadToken == token else { return }
                self.image = loaded
                self.isLoading = false
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented else { return event }
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 123, 126:
                self.go(-1)
                return nil
            case 124, 125:
                self.go(1)
                return nil
            case 53:
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

struct ImageGalleryView: View {
    @ObservedObject var gallery: ImageGallery

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { gallery.close() }

            VStack(spacing: 0) {
                toolbar
                imageStage
                footer
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            gallery.go(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            gallery.go(1)
            return .handled
        }
        .onKeyPress(.escape) {
            gallery.close()
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(gallery.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text(gallery.positionLabel)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            Button {
                gallery.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderless)
            .help("Full Screen")
            Button {
                gallery.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var imageStage: some View {
        ZStack {
            if let image = gallery.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if gallery.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                Text("Can’t open this image")
                    .foregroundStyle(.white.opacity(0.7))
            }

            if gallery.urls.count > 1 {
                HStack {
                    navButton(systemImage: "chevron.left") { gallery.go(-1) }
                    Spacer()
                    navButton(systemImage: "chevron.right") { gallery.go(1) }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var footer: some View {
        HStack {
            if let url = gallery.currentURL {
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            if gallery.urls.count > 1 {
                Text("← → to browse  ·  Esc to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("Esc to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func navButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
