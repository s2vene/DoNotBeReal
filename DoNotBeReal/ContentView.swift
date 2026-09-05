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
            Picker("촬영 모드", selection: $mode) {
                ForEach(CaptureMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }.pickerStyle(.segmented)
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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    switch result.kind {
                    case .photos(let photos): PhotoPairView(photos: photos)
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
            .sheet(isPresented: $showShare) { ShareSheet(items: result.shareItems) }
            .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(message ?? "") }
        }.preferredColorScheme(.dark)
    }

    private func save() {
        Task {
            do { try await result.saveToPhotoLibrary(); message = "사진 앱에 저장했습니다." }
            catch { message = error.localizedDescription }
        }
    }
}

private struct PhotoPairView: View {
    let photos: [CapturedPhoto]
    @State private var primaryIndex = 0

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
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            primaryIndex = secondaryIndex
                        }
                    } label: {
                        Image(uiImage: photos[secondaryIndex].image)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geometry.size.width * 0.31,
                                height: geometry.size.width * 0.31 * 4 / 3
                            )
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.black, lineWidth: 3)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
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
