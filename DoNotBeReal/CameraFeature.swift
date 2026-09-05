import SwiftUI
import AVFoundation
import Photos
import CoreImage
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, video
    var id: Self { self }
    var title: String { self == .photo ? "사진" : "동영상" }
    var icon: String { self == .photo ? "camera" : "video" }
}

enum CameraSide: String, CaseIterable, Identifiable {
    case front, back
    var id: Self { self }
    var title: String { self == .front ? "전면" : "후면" }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
    var opposite: CameraSide { self == .front ? .back : .front }
}

struct CapturedPhoto {
    let side: CameraSide
    let image: UIImage
}

struct CaptureResult: Identifiable {
    enum Kind { case photos([CapturedPhoto]); case video(URL) }
    let id = UUID()
    let kind: Kind

    var shareItems: [Any] {
        switch kind {
        case .photos(let photos): photos.map(\.image)
        case .video(let url): [url]
        }
    }

    @MainActor func saveToPhotoLibrary() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            switch kind {
            case .photos(let photos): photos.forEach { PHAssetChangeRequest.creationRequestForAsset(from: $0.image) }
            case .video(let url): PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }
}

enum CameraError: LocalizedError {
    case cameraDenied, microphoneDenied, cameraUnavailable, multiCamUnavailable
    case configurationFailed, captureFailed, recordingFailed, photoLibraryDenied
    var errorDescription: String? {
        switch self {
        case .cameraDenied: "설정에서 카메라 접근을 허용해 주세요."
        case .microphoneDenied: "동영상 녹화를 위해 설정에서 마이크 접근을 허용해 주세요."
        case .cameraUnavailable: "사용 가능한 카메라를 찾지 못했습니다."
        case .multiCamUnavailable: "이 기기는 전·후면 동시 촬영을 지원하지 않습니다."
        case .configurationFailed: "카메라를 구성하지 못했습니다."
        case .captureFailed: "사진 촬영에 실패했습니다."
        case .recordingFailed: "동영상 녹화에 실패했습니다."
        case .photoLibraryDenied: "설정에서 사진 추가 권한을 허용해 주세요."
        }
    }
}

@MainActor final class CameraController: ObservableObject {
    let photoSession = AVCaptureSession()
    let multiSession = AVCaptureMultiCamSession()
    @Published var result: CaptureResult?
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var countdown = 0
    @Published var isRecording = false
    @Published var recordingTime: Double = 0
    @Published var zoomFactor: CGFloat = 1
    @Published var minimumZoom: CGFloat = 1
    @Published var maximumZoom: CGFloat = 5
    @Published var multiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
    @Published var isVideoReady = false

    private let sessionQueue = DispatchQueue(label: "com.donotbereal.camera.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.donotbereal.camera.samples", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var photoInput: AVCaptureDeviceInput?
    private var photoDelegate: PhotoDelegate?
    private var timer: Timer?
    private var recorder: MultiCamRecorder?
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentSide: CameraSide = .front
    private(set) var zoomAtGestureStart: CGFloat = 1

    func prepare(for mode: CaptureMode, side: CameraSide) async {
        guard await requestAccess(for: .video) else { errorMessage = CameraError.cameraDenied.localizedDescription; return }
        changeMode(to: mode, side: side)
    }

    func changeMode(to mode: CaptureMode, side: CameraSide) {
        stopSessions()
        isVideoReady = false
        if mode == .photo { selectCamera(side) }
        else {
            Task {
                guard await requestAccess(for: .audio) else { errorMessage = CameraError.microphoneDenied.localizedDescription; return }
                configureMultiCam()
            }
        }
    }

    func selectCamera(_ side: CameraSide) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.currentSide != side || self.photoInput == nil {
                    try self.configurePhotoSession(side: side)
                }
                if !self.photoSession.isRunning { self.photoSession.startRunning() }
                let device = self.photoInput?.device
                Task { @MainActor in self.updateZoomRange(device: device) }
            } catch { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }

    func capturePair(startingWith side: CameraSide) {
        guard !isBusy else { return }
        isBusy = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.currentSide != side || self.photoInput == nil {
                    try self.configurePhotoSession(side: side)
                }
                if !self.photoSession.isRunning { self.photoSession.startRunning() }
                self.capturePhoto(side: side) { firstResult in
                    switch firstResult {
                    case .failure(let error): self.finishWithError(error)
                    case .success(let first):
                        self.sessionQueue.async {
                            do {
                                try self.configurePhotoSession(side: side.opposite)
                                Task { @MainActor in self.beginCountdown() }
                                self.sessionQueue.asyncAfter(deadline: .now() + 2) {
                                    self.capturePhoto(side: side.opposite) { secondResult in
                                        switch secondResult {
                                        case .failure(let error): self.finishWithError(error)
                                        case .success(let second):
                                            self.sessionQueue.async { try? self.configurePhotoSession(side: side) }
                                            Task { @MainActor in
                                                self.countdown = 0; self.isBusy = false
                                                self.result = CaptureResult(kind: .photos([first, second]))
                                            }
                                        }
                                    }
                                }
                            } catch { self.finishWithError(error) }
                        }
                    }
                }
            } catch { self.finishWithError(error) }
        }
    }

    func setZoom(_ value: CGFloat) {
        zoomFactor = min(max(value, minimumZoom), maximumZoom)
        let target = zoomFactor
        sessionQueue.async { [weak self] in
            guard let device = self?.photoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(max(target, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.unlockForConfiguration()
            } catch {}
        }
    }
    func finishZoomGesture() { zoomAtGestureStart = zoomFactor }

    func startRecording() {
        guard multiCamSupported, isVideoReady, !isRecording,
              backVideoOutput != nil, frontVideoOutput != nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DoNotBeReal-\(UUID().uuidString).mov")
        let recorder = MultiCamRecorder(outputURL: url, callbackQueue: sampleQueue)
        self.recorder = recorder
        backVideoOutput?.setSampleBufferDelegate(recorder, queue: sampleQueue)
        frontVideoOutput?.setSampleBufferDelegate(recorder, queue: sampleQueue)
        audioOutput?.setSampleBufferDelegate(recorder, queue: sampleQueue)
        recorder.identify(back: backVideoOutput, front: frontVideoOutput, audio: audioOutput)
        recorder.start()
        isRecording = true; recordingTime = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingTime += 1
                if self.recordingTime >= 60 { self.stopRecording() }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; timer?.invalidate(); timer = nil
        let activeRecorder = recorder; recorder = nil
        activeRecorder?.stop { [weak self] outcome in
            Task { @MainActor in
                switch outcome {
                case .success(let url): self?.result = CaptureResult(kind: .video(url))
                case .failure(let error): self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func attachPreviewLayers(back: AVCaptureVideoPreviewLayer, front: AVCaptureVideoPreviewLayer) {
        sessionQueue.async { [weak self, weak back, weak front] in
            guard let self, let back, let front,
                  let backPort = self.backInput?.ports.first(where: { $0.mediaType == .video }),
                  let frontPort = self.frontInput?.ports.first(where: { $0.mediaType == .video }) else { return }
            self.multiSession.beginConfiguration()
            defer { self.multiSession.commitConfiguration() }
            if back.connection == nil {
                let connection = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: back)
                if self.multiSession.canAddConnection(connection) { self.multiSession.addConnection(connection) }
            }
            if front.connection == nil {
                let connection = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: front)
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
                if self.multiSession.canAddConnection(connection) { self.multiSession.addConnection(connection) }
            }
        }
    }

    private func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: type)
        default: false
        }
    }

    private func stopSessions() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.photoSession.isRunning { self.photoSession.stopRunning() }
            if self.multiSession.isRunning { self.multiSession.stopRunning() }
        }
    }

    private func configurePhotoSession(side: CameraSide) throws {
        let device = try cameraDevice(for: side, multiCam: false)
        let input = try AVCaptureDeviceInput(device: device)
        photoSession.beginConfiguration(); defer { photoSession.commitConfiguration() }
        photoSession.sessionPreset = .photo
        photoSession.inputs.forEach(photoSession.removeInput)
        if photoSession.outputs.isEmpty, photoSession.canAddOutput(photoOutput) { photoSession.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        guard photoSession.canAddInput(input) else { throw CameraError.configurationFailed }
        photoSession.addInput(input); photoInput = input; currentSide = side; setWidestZoom(on: device)
    }

    private func capturePhoto(side: CameraSide, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        let settings = AVCapturePhotoSettings(); settings.flashMode = .off
        settings.photoQualityPrioritization = .quality
        let delegate = PhotoDelegate(side: side) { [weak self] result in completion(result); self?.photoDelegate = nil }
        photoDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func configureMultiCam() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            multiCamSupported = false; errorMessage = CameraError.multiCamUnavailable.localizedDescription; return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                let backDevice = try self.cameraDevice(for: .back, multiCam: true)
                let frontDevice = try self.cameraDevice(for: .front, multiCam: true)
                let backInput = try AVCaptureDeviceInput(device: backDevice)
                let frontInput = try AVCaptureDeviceInput(device: frontDevice)
                let backOutput = AVCaptureVideoDataOutput(), frontOutput = AVCaptureVideoDataOutput()
                let audioOutput = AVCaptureAudioDataOutput()
                backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                backOutput.alwaysDiscardsLateVideoFrames = true; frontOutput.alwaysDiscardsLateVideoFrames = true
                self.multiSession.beginConfiguration()
                self.multiSession.inputs.forEach(self.multiSession.removeInput)
                self.multiSession.outputs.forEach(self.multiSession.removeOutput)
                guard self.multiSession.canAddInput(backInput), self.multiSession.canAddInput(frontInput) else {
                    self.multiSession.commitConfiguration(); throw CameraError.configurationFailed
                }
                self.multiSession.addInputWithNoConnections(backInput); self.multiSession.addInputWithNoConnections(frontInput)
                guard self.multiSession.canAddOutput(backOutput), self.multiSession.canAddOutput(frontOutput) else {
                    self.multiSession.commitConfiguration(); throw CameraError.configurationFailed
                }
                self.multiSession.addOutputWithNoConnections(backOutput); self.multiSession.addOutputWithNoConnections(frontOutput)
                guard let backPort = backInput.ports.first(where: { $0.mediaType == .video }),
                      let frontPort = frontInput.ports.first(where: { $0.mediaType == .video }) else {
                    self.multiSession.commitConfiguration(); throw CameraError.configurationFailed
                }
                let backConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
                let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
                if backConnection.isVideoRotationAngleSupported(90) { backConnection.videoRotationAngle = 90 }
                if frontConnection.isVideoRotationAngleSupported(90) { frontConnection.videoRotationAngle = 90 }
                if frontConnection.isVideoMirroringSupported { frontConnection.isVideoMirrored = true }
                guard self.multiSession.canAddConnection(backConnection), self.multiSession.canAddConnection(frontConnection) else {
                    self.multiSession.commitConfiguration(); throw CameraError.configurationFailed
                }
                self.multiSession.addConnection(backConnection); self.multiSession.addConnection(frontConnection)
                if let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
                   self.multiSession.canAddInput(micInput) {
                    self.multiSession.addInputWithNoConnections(micInput)
                    if self.multiSession.canAddOutput(audioOutput) {
                        self.multiSession.addOutputWithNoConnections(audioOutput)
                        if let port = micInput.ports.first(where: { $0.mediaType == .audio }) {
                            let connection = AVCaptureConnection(inputPorts: [port], output: audioOutput)
                            if self.multiSession.canAddConnection(connection) { self.multiSession.addConnection(connection) }
                        }
                    }
                }
                self.multiSession.commitConfiguration()
                self.setWidestZoom(on: backDevice); self.setWidestZoom(on: frontDevice)
                self.backInput = backInput; self.frontInput = frontInput
                self.backVideoOutput = backOutput; self.frontVideoOutput = frontOutput; self.audioOutput = audioOutput
                self.multiSession.startRunning()
                Task { @MainActor in self.isVideoReady = true }
            } catch { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }

    private func cameraDevice(for side: CameraSide, multiCam: Bool) throws -> AVCaptureDevice {
        let types: [AVCaptureDevice.DeviceType]
        if side == .front { types = [.builtInTrueDepthCamera, .builtInWideAngleCamera] }
        else if multiCam { types = [.builtInUltraWideCamera, .builtInWideAngleCamera] }
        else { types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInUltraWideCamera, .builtInWideAngleCamera] }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: side.position).devices
        guard let device = devices.first else { throw CameraError.cameraUnavailable }
        return device
    }

    private func setWidestZoom(on device: AVCaptureDevice) {
        do { try device.lockForConfiguration(); device.videoZoomFactor = device.minAvailableVideoZoomFactor; device.unlockForConfiguration() }
        catch {}
    }

    private func updateZoomRange(device: AVCaptureDevice?) {
        guard let device else { return }
        minimumZoom = device.minAvailableVideoZoomFactor; maximumZoom = min(device.maxAvailableVideoZoomFactor, 5)
        zoomFactor = minimumZoom; zoomAtGestureStart = minimumZoom
    }

    private func beginCountdown() {
        countdown = 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.isBusy == true { self?.countdown = 1 } }
    }

    private nonisolated func finishWithError(_ error: Error) {
        Task { @MainActor in self.countdown = 0; self.isBusy = false; self.errorMessage = error.localizedDescription }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let side: CameraSide
    let completion: (Result<CapturedPhoto, Error>) -> Void
    init(side: CameraSide, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) { self.side = side; self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(.failure(CameraError.captureFailed)); return
        }
        completion(.success(CapturedPhoto(side: side, image: side == .front ? image.mirroredHorizontally : image)))
    }
}

private extension UIImage {
    var mirroredHorizontally: UIImage {
        guard let cgImage else { return self }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .upMirrored)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView { let view = PreviewUIView(); view.previewLayer.session = session; return view }
    func updateUIView(_ view: PreviewUIView, context: Context) { view.previewLayer.session = session }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) { super.init(frame: frame); previewLayer.videoGravity = .resizeAspectFill }
    required init?(coder: NSCoder) { fatalError() }
}

struct MultiCameraPreview: UIViewRepresentable {
    let controller: CameraController
    func makeUIView(context: Context) -> MultiPreviewUIView {
        let view = MultiPreviewUIView(session: controller.multiSession)
        controller.attachPreviewLayers(back: view.backLayer, front: view.frontLayer)
        return view
    }
    func updateUIView(_ view: MultiPreviewUIView, context: Context) {
        controller.attachPreviewLayers(back: view.backLayer, front: view.frontLayer)
    }
}

final class MultiPreviewUIView: UIView {
    let backLayer: AVCaptureVideoPreviewLayer
    let frontLayer: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        backLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        super.init(frame: .zero)
        backLayer.videoGravity = .resizeAspectFill; frontLayer.videoGravity = .resizeAspectFill
        frontLayer.cornerRadius = 16; frontLayer.masksToBounds = true
        frontLayer.borderColor = UIColor.white.cgColor; frontLayer.borderWidth = 2
        layer.addSublayer(backLayer); layer.addSublayer(frontLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews(); backLayer.frame = bounds
        frontLayer.frame = CGRect(x: bounds.maxX - 134, y: 14, width: 120, height: 160)
    }
}

private final class MultiCamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let outputURL: URL, queue: DispatchQueue
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var writer: AVAssetWriter?, videoInput: AVAssetWriterInput?, audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?, latestFront: CIImage?, startTime: CMTime?
    private var acceptingSamples = false
    private weak var backOutput: AVCaptureVideoDataOutput?, frontOutput: AVCaptureVideoDataOutput?, audioOutput: AVCaptureAudioDataOutput?
    private let outputSize = CGSize(width: 1080, height: 1440)

    init(outputURL: URL, callbackQueue: DispatchQueue) { self.outputURL = outputURL; self.queue = callbackQueue }
    func identify(back: AVCaptureVideoDataOutput?, front: AVCaptureVideoDataOutput?, audio: AVCaptureAudioDataOutput?) {
        backOutput = back; frontOutput = front; audioOutput = audio
    }
    func start() { queue.async { self.acceptingSamples = true } }
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            self.acceptingSamples = false
            guard let writer = self.writer, writer.status == .writing else { completion(.failure(CameraError.recordingFailed)); return }
            self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
            writer.finishWriting {
                writer.status == .completed ? completion(.success(self.outputURL)) : completion(.failure(writer.error ?? CameraError.recordingFailed))
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard acceptingSamples else { return }
        if output === frontOutput {
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) { latestFront = CIImage(cvPixelBuffer: buffer) }
        } else if output === backOutput { appendVideo(sampleBuffer) }
        else if output === audioOutput { appendAudio(sampleBuffer) }
    }

    private func configureWriter(at time: CMTime, formatHint: CMFormatDescription?) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1440,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: formatHint)
        videoInput.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1440]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 96_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw CameraError.recordingFailed }
        writer.add(videoInput); writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? CameraError.recordingFailed }
        writer.startSession(atSourceTime: time)
        self.writer = writer; self.videoInput = videoInput; self.audioInput = audioInput
        self.adaptor = adaptor; self.startTime = time
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            do { try configureWriter(at: time, formatHint: CMSampleBufferGetFormatDescription(sampleBuffer)) }
            catch { acceptingSamples = false; return }
        }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer), let videoInput, videoInput.isReadyForMoreMediaData,
              let pool = adaptor?.pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination else { return }
        var composite = aspectFill(CIImage(cvPixelBuffer: source), in: CGRect(origin: .zero, size: outputSize))
        if let latestFront {
            let rect = CGRect(x: 720, y: 56, width: 300, height: 400)
            composite = aspectFill(latestFront, in: rect).composited(over: composite)
        }
        context.render(composite, to: destination, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor?.append(destination, withPresentationTime: time)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing, let startTime,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startTime,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    private func aspectFill(_ image: CIImage, in target: CGRect) -> CIImage {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = max(target.width / normalized.extent.width, target.height / normalized.extent.height)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: target.minX + (target.width - scaled.extent.width) / 2,
            y: target.minY + (target.height - scaled.extent.height) / 2
        )).cropped(to: target)
    }
}
