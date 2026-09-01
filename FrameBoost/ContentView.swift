import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = FrameBoostModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    videoCard
                    settingsCard
                    if model.selectedVideoURL != nil { processCard }
                    if model.outputURL != nil { resultCard }
                    if let error = model.errorMessage { errorCard(error) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("FrameBoost")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .task(id: selectedItem) {
            guard let item = selectedItem else { return }
            do {
                guard let imported = try await item.loadTransferable(type: VideoTransferable.self) else {
                    model.errorMessage = "Unable to import this video. Please choose another video."
                    return
                }
                model.selectedVideoURL = imported.url
                model.outputURL = nil
                model.errorMessage = nil
            } catch {
                model.errorMessage = "Unable to import this video. Please try a different video."
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.tv.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(.tint)
            Text("Make your videos smoother").font(.system(.largeTitle, design: .rounded).weight(.bold)).multilineTextAlignment(.center).minimumScaleFactor(0.75)
            Text("Frame interpolation for smooth 60 FPS and 120 FPS exports, ready for TikTok.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    private var videoCard: some View {
        let hasVideo = model.selectedVideoURL != nil
        return VStack(alignment: .leading, spacing: 14) {
            Label("Source video", systemImage: "video.fill").font(.headline)
            PhotosPicker(selection: $selectedItem, matching: .videos, photoLibrary: .shared()) {
                Label(hasVideo ? "Choose another video" : "Choose video", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 58)
            }.buttonStyle(.borderedProminent)
            if hasVideo { Label("Video selected", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium)).foregroundStyle(.green) }
        }.padding(18).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export", systemImage: "slider.horizontal.3").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame rate").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Picker("Frame rate", selection: $model.settings.targetFPS) { Text("60 FPS").tag(60); Text("120 FPS").tag(120) }.pickerStyle(.segmented).disabled(model.isProcessing || model.selectedVideoURL == nil)
            }
            Toggle("Preserve original audio", isOn: $model.settings.preserveAudio).disabled(model.isProcessing || model.selectedVideoURL == nil)
            Text("Vertical 9:16 videos stay vertical. Other aspect ratios are preserved without stretching.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var processCard: some View {
        VStack(spacing: 14) {
            Button { model.startProcessing() } label { Label("Boost to \(model.settings.targetFPS) FPS", systemImage: "wand.and.stars").font(.headline).frame(maxWidth: .infinity, minHeight: 60) }.buttonStyle(.borderedProminent).disabled(model.isProcessing)
            if model.isProcessing { ProgressView(value: model.progress) { Text("Processing \(Int(model.progress * 100))%").font(.subheadline.weight(.medium)) }; Button("Cancel") { model.cancel() }.buttonStyle(.bordered) }
        }.padding(18).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var resultCard: some View {
        VStack(spacing: 12) {
            Label("Ready for TikTok", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Button { showShare = true } label { Label("Save / Share Video", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 58) }.buttonStyle(.borderedProminent)
                .sheet(isPresented: $showShare) { if let output = model.outputURL { ShareSheet(items: [output]).presentationDetents([.medium, .large]) } }
        }.padding(18).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func errorCard(_ message: String) -> some View { Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(16).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
}

private struct VideoTransferable: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostInput-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview { ContentView() }
