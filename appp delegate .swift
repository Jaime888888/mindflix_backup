import UIKit
import Flutter
import AVFoundation
import Vision

@main
class AppDelegate: FlutterAppDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

  // MethodChannel to Flutter
  private var channel: FlutterMethodChannel!

  // Camera
  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "gaze.camera.queue")

  // Latest normalized gaze (0..1)
  private var nx: Double = 0.5
  private var ny: Double = 0.5

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let controller = window?.rootViewController as! FlutterViewController
    channel = FlutterMethodChannel(name: "eye_tracker", binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "getGaze" {
        result(["x": self.nx, "y": self.ny])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    setupCamera()

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupCamera() {
    session.beginConfiguration()
    session.sessionPreset = .vga640x480

    // Front camera
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                               for: .video,
                                               position: .front),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else {
      session.commitConfiguration()
      return
    }
    session.addInput(input)

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    videoOutput.connection(with: .video)?.isEnabled = true
    videoOutput.connection(with: .video)?.isVideoMirrored = true // selfie view

    session.commitConfiguration()
    session.startRunning()
  }

  // Called for each camera frame
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {

    guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    // Vision face + landmarks request
    let faceReq = VNDetectFaceLandmarksRequest { [weak self] req, _ in
      guard let self = self else { return }
      guard let face = (req.results as? [VNFaceObservation])?.first else { return }

      // Try pupils first; fall back to average of eyes.
      func facePoint(_ lm: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let lm = lm, lm.pointCount > 0 else { return nil }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for i in 0..<lm.pointCount {
          let p = lm.normalizedPoints[Int(i)]
          sx += p.x; sy += p.y
        }
        return CGPoint(x: sx / CGFloat(lm.pointCount), y: sy / CGFloat(lm.pointCount))
      }

      let pL = facePoint(face.landmarks?.leftPupil) ?? facePoint(face.landmarks?.leftEye)
      let pR = facePoint(face.landmarks?.rightPupil) ?? facePoint(face.landmarks?.rightEye)

      // If both eyes found, use their midpoint; else use face center
      var p = CGPoint(x: 0.5, y: 0.5)
      if let l = pL, let r = pR {
        p = CGPoint(x: (l.x + r.x) * 0.5, y: (l.y + r.y) * 0.5)
      }

      // Landmarks are normalized within the face box (origin bottom-left).
      let f = face.boundingBox // normalized in image coords
      let gx = f.origin.x + p.x * f.size.width
      let gy = f.origin.y + p.y * f.size.height

      // Convert Vision (origin bottom-left) to UIKit-like top-left
      let nyVision = 1.0 - gy

      // Update normalized gaze (clamped)
      self.nx = max(0.0, min(1.0, Double(gx)))
      self.ny = max(0.0, min(1.0, Double(nyVision)))
    }

    let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .upMirrored, options: [:])
    try? handler.perform([faceReq])
  }
}
