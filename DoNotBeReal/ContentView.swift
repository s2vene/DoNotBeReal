import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var mode: CaptureMode = .photo
    @State private var firstCamera: CameraSide = .front
    @State private var result: CaptureResult?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Group {
                    if mode == .video { MultiCameraPreview(controller: camera) }
                    else { CameraPreview(session: camera.photoSession) }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .top) { statusOverlay }
                .overlay { waitingOverlay }
                .overlay {
                    if camera.shutterFlashVisible, mode == .photo {
                        Color.black.opacity(0.62).allowsHitTesting(false)
                    }
                }
                .gesture(zoomGesture)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .task { await camera.prepare(for: .photo, side: .front) }
        .onChange(of: mode) { _, value in camera.changeMode(to: value, side: firstCamera) }
        .onChange(of: firstCamera) { _, value in if mode == .photo { camera.selectCamera(value) } }
        .onReceive(camera.$result.compactMap { $0 }) { value in result = value; camera.result = nil }
        .fullScreenCover(item: $result) { ResultView(result: $0) }
        .alert("카메라를 사용할 수 없어요", isPresented: Binding(
            get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } }
        )) { Button("확인", role: .cancel) {} } message: {
            Text(camera.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Text("DoNotBeReal").font(.title2.bold())
                Spacer()
                if mode == .video, camera.isRecording {
                    Label(camera.recordingTime.clockText, systemImage: "record.circle.fill")
                        .font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.red)
                }
            }
            if mode == .photo {
                Picker("먼저 촬영할 카메라", selection: $firstCamera) {
                    ForEach(CameraSide.allCases) { Text("\($0.title) 먼저").tag($0) }
                }.pickerStyle(.segmented)
            }
        }.padding(.vertical, 14)
    }

    @ViewBuilder private var statusOverlay: some View {
        if mode == .video {
            Text(!camera.multiCamSupported ? "이 기기는 동시 촬영을 지원하지 않아요" :
                    (camera.isVideoReady ? "후면 + 전면 동시 촬영" : "카메라 준비 중…"))
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule()).padding(.top, 16)
        }
    }

    @ViewBuilder private var waitingOverlay: some View {
        if let image = camera.waitingImage, mode == .photo {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                Color.black.opacity(0.48)

                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.15)
                    Text("대기중...")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if mode == .photo, firstCamera == .back {
                HStack {
                    Text(camera.minimumZoom.zoomText)
                    Slider(value: Binding(get: { camera.zoomFactor }, set: { camera.setZoom($0) }),
                           in: camera.minimumZoom...camera.maximumZoom)
                    Text(camera.maximumZoom.zoomText)
                }.font(.caption.monospacedDigit()).padding(.top, 12)
            }
            Button {
                if mode == .photo { camera.capturePair(startingWith: firstCamera) }
                else if camera.isRecording { camera.stopRecording() }
                else { camera.startRecording() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    if mode == .video, camera.isRecording {
                        RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(mode == .video ? .red : .white).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(camera.isBusy || (mode == .video && (!camera.multiCamSupported || !camera.isVideoReady)))
            .opacity(camera.isBusy ? 0.5 : 1)
            Text(mode == .photo ? "한 번 누르면 두 카메라가 차례로 촬영돼요" : "최대 1분 · 다시 누르면 종료")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).frame(minHeight: 128)
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if mode == .photo, firstCamera == .back { camera.setZoom(camera.zoomAtGestureStart * value.magnification) }
            }
            .onEnded { _ in camera.finishZoomGesture() }
    }
}

private struct ResultView: View {
    let result: CaptureResult
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var message: String?
    @State private var primaryIndex = 0
    @State private var pipCorner: PiPCorner = .topLeading

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    switch result.kind {
                    case .photos(let photos):
                        PhotoPairView(photos: photos, primaryIndex: $primaryIndex, pipCorner: $pipCorner)
                    case .video(let url): VideoPlayer(player: AVPlayer(url: url)).aspectRatio(3 / 4, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .navigationTitle("촬영 결과").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("다시 찍기") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: result.shareItems(primaryIndex: primaryIndex, corner: pipCorner))
            }
            .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(message ?? "") }
        }.preferredColorScheme(.dark)
    }

    private func save() {
        Task {
            do {
                try await result.saveToPhotoLibrary(primaryIndex: primaryIndex, corner: pipCorner)
                message = "사진 앱에 저장했습니다."
            }
            catch { message = error.localizedDescription }
        }
    }
}

private struct PhotoPairView: View {
    let photos: [CapturedPhoto]
    @Binding var primaryIndex: Int
    @Binding var pipCorner: PiPCorner
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if photos.indices.contains(primaryIndex) {
                    Image(uiImage: photos[primaryIndex].image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }

                if photos.count > 1 {
                    let secondaryIndex = primaryIndex == 0 ? 1 : 0
                    let pipWidth = geometry.size.width * 0.31
                    let pipSize = CGSize(width: pipWidth, height: pipWidth * 4 / 3)
                    let origin = pipOrigin(container: geometry.size, pip: pipSize)
                    Image(uiImage: photos[secondaryIndex].image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: pipSize.width, height: pipSize.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.black, lineWidth: 3)
                        }
                        .contentShape(Rectangle())
                        .position(
                            x: origin.x + pipSize.width / 2 + dragOffset.width,
                            y: origin.y + pipSize.height / 2 + dragOffset.height
                        )
                        .onTapGesture { primaryIndex = secondaryIndex }
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .updating($dragOffset) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    let center = CGPoint(
                                        x: origin.x + pipSize.width / 2 + value.translation.width,
                                        y: origin.y + pipSize.height / 2 + value.translation.height
                                    )
                                    let trailing = center.x >= geometry.size.width / 2
                                    let bottom = center.y >= geometry.size.height / 2
                                    withAnimation(.snappy(duration: 0.22)) {
                                        pipCorner = switch (trailing, bottom) {
                                        case (false, false): .topLeading
                                        case (true, false): .topTrailing
                                        case (false, true): .bottomLeading
                                        case (true, true): .bottomTrailing
                                        }
                                    }
                                }
                        )
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
    }

    private func pipOrigin(container: CGSize, pip: CGSize) -> CGPoint {
        let margin: CGFloat = 14
        return CGPoint(
            x: pipCorner.isTrailing ? container.width - margin - pip.width : margin,
            y: pipCorner.isBottom ? container.height - margin - pip.height : margin
        )
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension Double { var clockText: String { String(format: "%01d:%02d", Int(self) / 60, Int(self) % 60) } }
private extension CGFloat { var zoomText: String { String(format: "%.1fx", self) } }
