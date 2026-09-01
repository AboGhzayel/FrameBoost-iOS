import PhotosUI
import SwiftUI

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var selectedURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier("public.movie") else { return }
            provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, _ in
                guard let url else { return }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostInput-\(UUID().uuidString).mov")
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    DispatchQueue.main.async { self.parent.selectedURL = destination }
                } catch { }
            }
        }
    }
}
