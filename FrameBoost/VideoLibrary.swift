import Photos
import UIKit

@MainActor
final class VideoLibrary: ObservableObject {
    @Published var authorizationDenied = false

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationDenied = status == .denied || status == .restricted
        return status == .authorized || status == .limited
    }

    func saveVideo(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
