import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var model = FrameBoostModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showShare = false
    @State private var selectedProfile: ProcessingProfile = .tiktokPro
    @Namespace private var glassNamespace

    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView(.vertical) {
                    VStack(spacing: 18) {
                        hero
                        sourceCard
                        processingCard
                        exportCard
                        if model.selectedVideoURL != nil { renderCard }
                        if model.outputURL != nil { resultCard }
                        if let error = model.errorMessage { errorCard(error) }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("FrameBoost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .tint(.blue)
        .task(id: selectedItem) {
            guard let item = selectedItem else { return }
            do {
                guard let imported = try await item.loadTransferable(type: VideoTransferable.self) else {
                    throw ImportError.failed
                }
                model.selectedVideoURL = imported.url
                model.outputURL = nil
                model.errorMessage = nil
            } catch {
                model.errorMessage = "Could not import this video. Please select a video saved in Photos and try again."
            }
        }
    }

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Circle().fill(.blue.opacity(0.13)).frame(width: 280, height: 280).blur(radius: 70).offset(x: 130, y: -260)
            Circle().fill(.purple.opacity(0.10)).frame(width: 260, height: 260).blur(radius: 80).offset(x: -150, y: 330)
        }
        .allowsHitTesting(false)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(.blue).interactive(), in: .circle)

            Text("FrameBoost")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .tracking(-1.2)

            Text("AI frame interpolation for smoother video")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                statusPill("RIFE AI", icon: "cpu")
                statusPill("60 / 120 FPS", icon: "film")
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func statusPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }

    private var sourceCard: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Source video", icon: "video.fill", subtitle: "Choose a clip from Photos")

                PhotosPicker(selection: $selectedItem, matching: .videos) {
                    HStack(spacing: 14) {
                        Image(systemName: model.selectedVideoURL == nil ? "photo.on.rectangle.angled" : "checkmark.circle.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .glassEffect(.clear, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.selectedVideoURL == nil ? "Choose video" : "Video selected").font(.headline)
                            Text(model.selectedVideoURL == nil ? "Import from your Photos library" : "Tap to replace the source video")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .glassEffectID("source", in: glassNamespace)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }

    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("AI processing", icon: "wand.and.stars", subtitle: "Choose how FrameBoost should render")

            Picker("Profile", selection: $selectedProfile) {
                ForEach(ProcessingProfile.allCases) { profile in
                    Text(profile.rawValue).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing || model.selectedVideoURL == nil)

            VStack(spacing: 8) {
                HStack {
                    Label("Frame rate", systemImage: "speedometer")
                    Spacer()
                    Text("\(selectedProfile.targetFPS) FPS").font(.subheadline.weight(.semibold))
                }
                Text(selectedProfile.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Export", icon: "slider.horizontal.3", subtitle: "Fine-tune the final video")

            HStack(spacing: 10) {
                fpsButton(60)
                fpsButton(120)
            }

            Toggle(isOn: $model.settings.preserveAudio) {
                Label("Preserve original audio", systemImage: "waveform")
            }
            .disabled(model.isProcessing || model.selectedVideoURL == nil)

            Label(
                selectedProfile == .tiktokPro ? "TikTok Pro • 1080×1920 • SDR" : "Portrait 9:16 • original framing preserved",
                systemImage: "iphone"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func fpsButton(_ fps: Int) -> some View {
        Button {
            model.settings.targetFPS = fps
        } label: {
            HStack {
                Image(systemName: fps == 60 ? "gauge.with.dots.needle.33percent" : "bolt.fill")
                Text("\(fps) FPS").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.glass)
        .disabled(model.isProcessing || model.selectedVideoURL == nil)
    }

    private var renderCard: some View {
        VStack(spacing: 14) {
            if model.isProcessing {
                VStack(spacing: 12) {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                    HStack {
                        Label("Rendering with RIFE AI", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(model.progress * 100))%")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                    }
                    Button("Cancel") { model.cancel() }.buttonStyle(.glass)
                }
            } else {
                Button {
                    model.settings.targetFPS = selectedProfile.targetFPS
                    model.startProcessing()
                } label: {
                    Label("Boost to \(selectedProfile.targetFPS) FPS", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.glassProminent)
                .glassEffectID("render", in: glassNamespace)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var resultCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to export").font(.headline)
                    Text("Your enhanced video is finished.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button { showShare = true } label: {
                Label("Save / Share Video", systemImage: "square.and.arrow.up")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.glassProminent)
            .sheet(isPresented: $showShare) {
                if let output = model.outputURL {
                    ShareSheet(items: [output]).presentationDetents([.medium, .large])
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.green.opacity(0.10)), in: .rect(cornerRadius: 28))
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(16)
            .glassEffect(.regular.tint(.red.opacity(0.10)), in: .rect(cornerRadius: 22))
    }

    private func sectionHeader(_ title: String, icon: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .frame(width: 38, height: 38)
                .glassEffect(.clear, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private enum ImportError: Error { case failed }

private struct VideoTransferable: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostInput-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
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
