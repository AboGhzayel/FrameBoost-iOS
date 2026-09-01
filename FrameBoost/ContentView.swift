import SwiftUI
import PhotosUI

@MainActor
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
                ScrollView {
                    VStack(spacing: 18) {
                        hero
                        sourceCard
                        processingCard
                        preprocessingCard
                        exportCard
                        if model.selectedVideoURL != nil { renderCard }
                        if model.outputURL != nil { resultCard }
                        if let error = model.errorMessage { errorCard(error) }
                    }
                    .frame(maxWidth: 720).frame(maxWidth: .infinity)
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 34)
                }.scrollIndicators(.hidden)
            }
            .navigationTitle("FrameBoost").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { PhotosPicker(selection: $selectedItem, matching: .videos) { Image(systemName: "plus").fontWeight(.semibold) }.buttonStyle(.glass) } }
        }
        .tint(.blue)
        .task(id: selectedItem) {
            guard let item = selectedItem else { return }
            do {
                guard let imported = try await item.loadTransferable(type: VideoTransferable.self) else { throw ImportError.failed }
                model.selectedVideoURL = imported.url
                model.outputURL = nil
                model.errorMessage = nil
            } catch {
                model.errorMessage = "Could not import this video. Please try again."
            }
        }
    }

    private var background: some View { ZStack { Color(uiColor: .systemBackground).ignoresSafeArea(); Circle().fill(.blue.opacity(0.13)).frame(width: 280, height: 280).blur(radius: 70).offset(x: 130, y: -260); Circle().fill(.purple.opacity(0.10)).frame(width: 260, height: 260).blur(radius: 80).offset(x: -150, y: 330) }.allowsHitTesting(false) }
    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.tv.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.white).frame(width: 72, height: 72).glassEffect(.regular.tint(.blue).interactive(), in: .circle)
            Text("FrameBoost").font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-1.2)
            Text("AI frame interpolation + smart video preparation").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) { statusPill("RIFE AI", icon: "cpu"); statusPill("Cloud AI", icon: "cloud.fill") }
        }.padding(.top, 8).padding(.bottom, 4)
    }
    private func statusPill(_ title: String, icon: String) -> some View { Label(title, systemImage: icon).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8).glassEffect(.regular, in: .capsule) }
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Source video", icon: "video.fill", subtitle: "Choose a clip from Photos")
            PhotosPicker(selection: $selectedItem, matching: .videos) {
                HStack(spacing: 14) { Image(systemName: model.selectedVideoURL == nil ? "photo.on.rectangle.angled" : "checkmark.circle.fill").font(.title3.weight(.semibold)).frame(width: 42, height: 42).glassEffect(.clear, in: .circle); VStack(alignment: .leading, spacing: 3) { Text(model.selectedVideoURL == nil ? "Choose video" : "Video selected").font(.headline); Text(model.selectedVideoURL == nil ? "Import from your Photos library" : "Tap to replace the source video").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary) }.padding(14)
            }.buttonStyle(.glass)
        }.padding(18).glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("AI processing", icon: "wand.and.stars", subtitle: "Choose where the heavy AI work runs")
            Picker("Mode", selection: $model.processingMode) { ForEach(ProcessingMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(model.isProcessing || model.selectedVideoURL == nil)
            HStack(spacing: 10) { Image(systemName: modeIcon).font(.headline).frame(width: 38, height: 38).glassEffect(.clear, in: .circle); VStack(alignment: .leading, spacing: 2) { Text(model.processingMode.rawValue).font(.subheadline.weight(.semibold)); Text(model.processingMode.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer() }
            Picker("Profile", selection: $selectedProfile) { ForEach(ProcessingProfile.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).disabled(model.isProcessing || model.selectedVideoURL == nil)
            Text(selectedProfile.description).font(.caption).foregroundStyle(.secondary)
        }.padding(18).glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
    private var modeIcon: String { switch model.processingMode { case .auto: return "wand.and.stars"; case .onDevice: return "iphone"; case .cloud: return "cloud.fill" } }
    private var preprocessingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Pre-process", icon: "dial.low", subtitle: "Re-encode locally before Cloud AI upload")
            Picker("Pre-processing", selection: $model.preprocessingProfile) { ForEach(PreprocessingProfile.allCases) { profile in Label(profile.rawValue, systemImage: profile == .motionBlur ? "wind" : profile == .studio ? "sparkles" : "hare").tag(profile) } }.pickerStyle(.segmented).disabled(model.isProcessing || model.selectedVideoURL == nil || model.processingMode == .onDevice)
            HStack(alignment: .top, spacing: 10) { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34).glassEffect(.clear, in: .circle); Text(model.preprocessingProfile.description).font(.caption).foregroundStyle(.secondary); Spacer() }
            if model.processingMode == .onDevice { Label("Pre-processing is only applied before Cloud AI upload; On Device keeps the original source.", systemImage: "iphone").font(.caption).foregroundStyle(.secondary) }
        }.padding(18).glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Export", icon: "slider.horizontal.3", subtitle: "Fine-tune the final video")
            HStack(spacing: 10) { fpsButton(60); fpsButton(120) }
            Toggle(isOn: $model.settings.preserveAudio) { Label("Preserve original audio", systemImage: "waveform") }.disabled(model.isProcessing || model.selectedVideoURL == nil)
            Label(selectedProfile == .tiktokPro ? "TikTok Pro • 1080×1920 • SDR" : "Original framing preserved", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
        }.padding(18).glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
    private func fpsButton(_ fps: Int) -> some View { Button { model.settings.targetFPS = fps } label: { HStack { Image(systemName: fps == 60 ? "gauge.with.dots.needle.33percent" : "bolt.fill"); Text("\(fps) FPS").fontWeight(.semibold) }.frame(maxWidth: .infinity, minHeight: 46) }.buttonStyle(.glass).disabled(model.isProcessing || model.selectedVideoURL == nil) }
    private var renderCard: some View {
        VStack(spacing: 14) {
            if model.isProcessing { VStack(spacing: 12) { ProgressView(value: model.progress).progressViewStyle(.linear); HStack { Label(model.cloudStatus ?? "Rendering with RIFE AI", systemImage: model.processingMode == .cloud ? "cloud.fill" : "sparkles").font(.subheadline.weight(.semibold)); Spacer(); Text("\(Int(model.progress * 100))%").font(.subheadline.monospacedDigit().weight(.bold)) }; Button("Cancel") { model.cancel() }.buttonStyle(.glass) } }
            else { Button { model.startProcessing() } label: { Label(model.processingMode == .cloud ? "Boost with Cloud AI" : "Boost on Device", systemImage: model.processingMode == .cloud ? "cloud.fill" : "wand.and.stars").font(.headline).frame(maxWidth: .infinity, minHeight: 58) }.buttonStyle(.glassProminent).glassEffectID("render", in: glassNamespace) }
        }.padding(18).glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
    private var resultCard: some View {
        VStack(spacing: 14) { HStack(spacing: 12) { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green); VStack(alignment: .leading, spacing: 3) { Text("Ready to export").font(.headline); Text("Your enhanced video is finished.").font(.caption).foregroundStyle(.secondary) }; Spacer() }; Button { showShare = true } label: { Label("Save / Share Video", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 56) }.buttonStyle(.glassProminent).sheet(isPresented: $showShare) { if let output = model.outputURL { ShareSheet(items: [output]).presentationDetents([.medium, .large]) } } }.padding(18).glassEffect(.regular.tint(.green.opacity(0.10)), in: .rect(cornerRadius: 28))
    }
    private func errorCard(_ message: String) -> some View { Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(16).glassEffect(.regular.tint(.red.opacity(0.10)), in: .rect(cornerRadius: 22)) }
    private func sectionHeader(_ title: String, icon: String, subtitle: String) -> some View { HStack(spacing: 12) { Image(systemName: icon).font(.headline.weight(.semibold)).frame(width: 38, height: 38).glassEffect(.clear, in: .circle); VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer() } }
}
private enum ImportError: Error { case failed }
private struct VideoTransferable: Transferable, Sendable { let url: URL; static var transferRepresentation: some TransferRepresentation { FileRepresentation(importedContentType: .movie) { received in let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension; let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostInput-\(UUID().uuidString).\(ext)"); try? FileManager.default.removeItem(at: destination); try FileManager.default.copyItem(at: received.file, to: destination); return Self(url: destination) } } }
private struct ShareSheet: UIViewControllerRepresentable { let items: [Any]; func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }; func updateUIViewController(_ controller: UIActivityViewController, context: Context) {} }
