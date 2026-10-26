import AppKit
import SwiftUI

@MainActor
struct CreateScreen: View {
    @ObservedObject var store: CreateStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Create").font(.title2.weight(.semibold))
                Text("Creating pauses earning on this Mac while it runs.")
                    .font(.callout).foregroundStyle(.secondary)
                if let reason = store.unavailableReason {
                    ShellPanel {
                        Label("Create unavailable", systemImage: "exclamationmark.circle")
                        Text(reason).foregroundStyle(.secondary)
                        Button("Retry") { Task { await store.refresh(port: ProviderConfig.readHTTPPort()) } }
                    }.accessibilityIdentifier("malibu.create.unavailable")
                }
                ShellPanel {
                    Text("Describe your image").font(.headline)
                    TextEditor(text: $store.prompt).frame(minHeight: 90, maxHeight: 160)
                        .accessibilityLabel("Image prompt").accessibilityIdentifier("malibu.create.prompt")
                    HStack {
                        Picker("Size", selection: $store.size) {
                            Text("512 × 512").tag("512x512")
                            if store.status?.supportsLargeImages == true {
                                Text("1024 × 1024").tag("1024x1024")
                            }
                        }.frame(maxWidth: 230)
                        Stepper("Steps: \(store.steps)", value: $store.steps, in: 1...4)
                            .frame(maxWidth: 180)
                    }
                    if store.status?.supportsLargeImages == false {
                        Text("1024 × 1024 requires at least 32 GB of memory.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Seed (optional)", text: $store.seed).frame(maxWidth: 300)
                        .accessibilityIdentifier("malibu.create.seed")
                    HStack {
                        Button("Generate") { store.generate() }.disabled(!store.canGenerate)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("malibu.create.generate")
                        if store.isRunning || store.status?.phase.busy == true {
                            Button("Stop") { Task { await store.cancel() } }
                                .accessibilityIdentifier("malibu.create.stop")
                        }
                    }
                }
                if let status = store.status {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.phase.label)
                        if status.phase == .downloading {
                            if let progress = status.progress { ProgressView(value: progress) }
                            else { ProgressView().controlSize(.small) }
                            if let size = status.downloadLabel { Text(size).font(.caption).foregroundStyle(.secondary) }
                        } else if status.phase.busy { ProgressView().controlSize(.small) }
                    }.accessibilityIdentifier("malibu.create.status")
                }
                if let notice = store.notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Gallery").font(.headline)
                Text("Saved to Pictures/Malibu").font(.caption).foregroundStyle(.secondary)
                if store.images.isEmpty { Text("Your images will appear here.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(store.images) { image in
                        VStack(alignment: .leading, spacing: 8) {
                            if let preview = NSImage(contentsOf: image.url) {
                                Image(nsImage: preview).resizable().scaledToFit()
                                    .frame(maxHeight: 300).accessibilityLabel("Generated image")
                            }
                            HStack {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
                                Button("Copy") {
                                    if let bitmap = NSImage(contentsOf: image.url) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.writeObjects([bitmap])
                                    }
                                }
                            }.font(.caption)
                        }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("malibu.create.screen")
        .task {
            while !Task.isCancelled {
                await store.refresh(port: ProviderConfig.readHTTPPort())
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
