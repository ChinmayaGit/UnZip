import AppKit
import SwiftUI

struct ShareSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var share: FileShare

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share")
                        .font(.title2.weight(.semibold))
                    Text(share.status)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 22) {
                qrColumn
                nearbyColumn
            }

            if !share.files.isEmpty {
                Text("Sharing")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(share.files) { file in
                            HStack {
                                Text(file.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteFormat.string(file.size))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            HStack {
                if share.isPublishing {
                    Button("Stop Sharing", role: .destructive) {
                        share.stopPublishing()
                    }
                } else {
                    Button("Share Selected") {
                        state.beginShare()
                    }
                }
                Spacer()
                Text("Same Wi‑Fi. No FTP setup.")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 460)
        .onAppear {
            share.start()
        }
    }

    private var qrColumn: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)
                if let image = share.qrImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 200, height: 200)
                } else {
                    ProgressView()
                }
            }
            Text("No UnZip on the other device?")
                .font(.headline)
            Text("Scan this QR or open the link in a browser to download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 240)
            if let url = share.shareURL {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        state.status = "Copied share link"
                    }
                    Button("Open Page") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(width: 260)
    }

    private var nearbyColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nearby UnZip")
                .font(.headline)
            Text("Other devices running this app show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if share.nearby.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No other UnZip nearby yet")
                        .foregroundStyle(.secondary)
                    Text("They should open UnZip on the same Wi‑Fi, or use the QR if they only need the files.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(share.nearby) { peer in
                            HStack {
                                Image(systemName: peer.isSharing ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                    .font(.title2)
                                    .foregroundStyle(peer.isSharing ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .font(.headline)
                                    Text(peer.isSharing ? "Sharing \(peer.fileCount) item\(peer.fileCount == 1 ? "" : "s")" : "Online, not sharing")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if peer.isSharing {
                                    Button("Receive") {
                                        state.receiveFromPeer(peer)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            if let note = share.receiveNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    }
}
