import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = FrameBoostModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(spacing: 18) {
                    header
                    videoPicker
                    settingsCard
                    actionArea
                    resultArea
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("FrameBoost")
                        .font(.headline.weight(.semibold))
                }
            }
            .task(id: selectedItem) {
                guard let selectedItem else { return }
                model.selectedVideoURL = try? await selectedItem
                    .loadTransferable(type: VideoTransferable.self)?.url
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("FrameBoost")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.8)

            Text("Boost your video frame rate with a clean, simple workflow.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.top, 4)
    }

    private var videoPicker: some View {
        PhotosPicker(selection: $selectedItem, matching: .videos) {
            Label(
                model.selectedVideoURL == nil ? "Choose Video" : "Video Selected",
                systemImage: model.selectedVideoURL == nil ? "plus.circle.fill" : "checkmark.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(model.selectedVideoURL == nil ? "Choose a video" : "Selected video")
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Output")
                .font(.headline)

            Picker("Output frame rate", selection: $model.settings.multiplier) {
                Text("2× FPS").tag(2)
                Text("4× FPS").tag(4)
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing || model.selectedVideoURL == nil)

            Toggle("Preserve audio", isOn: $model.settings.preserveAudio)
                .disabled(model.isProcessing || model.selectedVideoURL == nil)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actionArea: some View {
        if model.selectedVideoURL != nil {
            VStack(spacing: 12) {
                Button {
                    Task { await model.process() }
                } label: {
                    Label("Process Video", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isProcessing)

                if model.isProcessing {
                    ProgressView(value: model.progress) {
                        Text("Processing…")
                    }
                    .tint(.accentColor)

                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        if let output = model.outputURL {
            Button {
                showShare = true
            } label: {
                Label("Share Result", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.bordered)
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [output])
                    .presentationDetents([.medium, .large])
            }
        }

        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
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
