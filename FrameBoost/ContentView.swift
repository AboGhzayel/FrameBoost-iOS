import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = FrameBoostModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showShare = false
    @State private var selectedProfile: ProcessingProfile = .tiktokPro

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    hero
                    videoCard
                    profileCard
                    settingsCard
                    if model.selectedVideoURL != nil { processCard }
                    if model.outputURL != nil { resultCard }
                    if let error = model.errorMessage { errorCard(error) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .task(id: selectedItem) {
            guard let item = selectedItem else { return }
            do {
                guard let imported = try await item.loadTransferable(type: VideoTransferable.self) else { throw ImportError.failed }
                model.selectedVideoURL = imported.url
                model.outputURL = nil
                model.errorMessage = nil
            } catch {
                model.errorMessage = "Could not import this video. Please select a video saved in Photos and try again."
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.tv.fill").font(.system(size: 42, weight: .bold)).foregroundStyle(.tint)
            Text("FrameBoost").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("AI-ready 60 FPS / 120 FPS video enhancement").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Source video", systemImage: "video.fill").font(.headline)
            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Label(model.selectedVideoURL == nil ? "Choose video" : "Choose another video", systemImage: "plus.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 58)
            }.buttonStyle(.borderedProminent)
            if model.selectedVideoURL != nil { Label("Video selected", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium)).foregroundStyle(.green) }
        }
        .padding(18).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Processing profile", systemImage: "wand.and.stars").font(.headline)
            Picker("Profile", selection: $selectedProfile) {
                ForEach(ProcessingProfile.allCases) { profile in Text(profile.rawValue).tag(profile) }
            }
            .pickerStyle(.menu)
            .disabled(model.isProcessing || model.selectedVideoURL == nil)
            Text(selectedProfile.description).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export", systemImage: "slider.horizontal.3").font(.headline)
            Picker("Frame rate", selection: $model.settings.targetFPS) { Text("60 FPS").tag(60); Text("120 FPS").tag(120) }
                .pickerStyle(.segmented).disabled(model.isProcessing || model.selectedVideoURL == nil)
            Toggle("Preserve original audio", isOn: $model.settings.preserveAudio).disabled(model.isProcessing || model.selectedVideoURL == nil)
            if selectedProfile == .tiktokPro {
                Label("TikTok Pro: vertical 1080×1920 + SDR export profile", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Portrait 9:16 is preserved without stretching.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var processCard: some View {
        VStack(spacing: 14) {
            Button {
                model.settings.targetFPS = selectedProfile.targetFPS
                model.startProcessing()
            } label: {
                Label("Boost with \(selectedProfile.rawValue)", systemImage: "wand.and.stars").font(.headline).frame(maxWidth: .infinity, minHeight: 60)
            }.buttonStyle(.borderedProminent).disabled(model.isProcessing)
            if model.isProcessing { ProgressView(value: model.progress) { Text("Processing \(Int(model.progress * 100))%") }; Button("Cancel") { model.cancel() }.buttonStyle(.bordered) }
        }
        .padding(18).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var resultCard: some View {
        VStack(spacing: 12) {
            Label("Ready", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Button { showShare = true } label: { Label("Save / Share Video", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 58) }
                .buttonStyle(.borderedProminent).sheet(isPresented: $showShare) { if let output = model.outputURL { ShareSheet(items: [output]).presentationDetents([.medium, .large]) } }
        }
        .padding(18).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func errorCard(_ message: String) -> some View { Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(16).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
}

private enum ImportError: Error { case failed }
private struct VideoTransferable: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation { FileRepresentation(importedContentType: .movie) { received in
        let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostInput-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: received.file, to: destination)
        return Self(url: destination)
    } }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
