import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = FrameBoostModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 58))
                        .symbolRenderingMode(.hierarchical)
                        .padding(.top, 20)

                    Text("FrameBoost")
                        .font(.largeTitle.bold())

                    Text("Boost your video frame rate with a clean, simple workflow.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label(model.selectedVideoURL == nil ? "Choose Video" : "Video Selected", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Picker("Output", selection: $model.settings.multiplier) {
                        Text("2× FPS").tag(2)
                        Text("4× FPS").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isProcessing || model.selectedVideoURL == nil)

                    Toggle("Preserve audio", isOn: $model.settings.preserveAudio)
                        .disabled(model.isProcessing || model.selectedVideoURL == nil)

                    if model.selectedVideoURL != nil {
                        Button {
                            Task { await model.process() }
                        } label: {
                            Label("Process Video", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProcessing)
                    }

                    if model.isProcessing {
                        ProgressView(value: model.progress)
                        Text("Processing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(.bordered)
                    }

                    if let output = model.outputURL {
                        Button {
                            showShare = true
                        } label: {
                            Label("Share Result", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .sheet(isPresented: $showShare) {
                            ShareSheet(items: [output])
                        }
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("FrameBoost")
            .task(id: selectedItem) {
                guard let selectedItem else { return }
                model.selectedVideoURL = try? await selectedItem.loadTransferable(type: VideoTransferable.self)?.url
            }
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

#Preview { ContentView() }
