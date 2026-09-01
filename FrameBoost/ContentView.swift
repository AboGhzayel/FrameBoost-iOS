import SwiftUI
import PhotosUI

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
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("FrameBoost")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: selectedItem) {
                guard let selectedItem else { return }
                model.selectedVideoURL = try? await selectedItem
                    .loadTransferable(type: VideoTransferable.self)?.url
                model.outputURL = nil
                model.errorMessage = nil
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            Text("Make your videos smoother")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)

            Text("Frame interpolation for smooth 60 FPS and 120 FPS exports, ready for TikTok.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(.vertical, 10)
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Source video", systemImage: "video.fill")
                .font(.headline)

            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Label(
                    model.selectedVideoURL == nil ? "Choose video" : "Choose another video",
                    systemImage: "plus.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)

            if model.selectedVideoURL != nil {
                Label("Video selected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export", systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Frame rate")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("Frame rate", selection: $model.settings.targetFPS) {
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                .pickerStyle(.segmented)
                .disabled(model.isProcessing || model.selectedVideoURL == nil)
            }

            Toggle("Preserve original audio", isOn: $model.settings.preserveAudio)
                .disabled(model.isProcessing || model.selectedVideoURL == nil)

            Text("9:16 videos stay 9:16. Other aspect ratios are preserved without stretching.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var processCard: some View {
        VStack(spacing: 14) {
            Button {
                Task { await model.process() }
            } label: {
                Label("Boost to \(model.settings.targetFPS) FPS", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isProcessing)

            if model.isProcessing {
                ProgressView(value: model.progress) {
                    Text("Processing \(Int(model.progress * 100))%")
                        .font(.subheadline.weight(.medium))
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var resultCard: some View {
        VStack(spacing: 12) {
            Label("Ready for TikTok", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Button { showShare = true } label: {
                Label("Save / Share Video", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .sheet(isPresented: $showShare) {
                if let output = model.outputURL {
                    ShareSheet(items: [output])
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("FrameBoostInput-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
