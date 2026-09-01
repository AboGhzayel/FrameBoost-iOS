import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var multiplier = 2
    @State private var isProcessing = false
    @State private var progress = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "film.stack.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)

                Text("FrameBoost")
                    .font(.largeTitle.bold())

                Text("Enhance your videos with higher frame rates.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                PhotosPicker(selection: $selectedItem, matching: .videos) {
                    Label(selectedVideoURL == nil ? "Choose Video" : "Video Selected", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Picker("Output", selection: $multiplier) {
                    Text("2× FPS").tag(2)
                    Text("4× FPS").tag(4)
                }
                .pickerStyle(.segmented)
                .disabled(selectedVideoURL == nil || isProcessing)

                if isProcessing {
                    ProgressView(value: progress)
                    Text("Processing \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("FrameBoost")
            .task(id: selectedItem) {
                guard let selectedItem else { return }
                selectedVideoURL = try? await selectedItem.loadTransferable(type: VideoTransferable.self)?.url
            }
        }
    }
}

private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

#Preview {
    ContentView()
}
