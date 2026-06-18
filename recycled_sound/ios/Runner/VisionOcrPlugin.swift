import Flutter
import Vision
import CoreGraphics
import ImageIO
import UIKit

/// Native iOS OCR via Apple's Vision framework.
///
/// Replaces (or runs alongside) ML Kit text recognition. Two advantages
/// over ML Kit for our hearing-aid use case:
///
/// 1. **customWords bias.** Vision lets us hand it a domain vocabulary
///    (hearing-aid brand and model tokens) which the recognizer prefers
///    during decoding. Empirically this turns "Oricon"-style misreads
///    into clean "Oticon" reads, fixing the garbled OCR problem
///    diagnosed in the 2026-05-07 profiling session.
///
/// 2. **Native iOS image orientation.** Vision takes a
///    `CGImagePropertyOrientation` directly, sidestepping the
///    ML-Kit-on-BGRA rotation-handling ambiguity that's been
///    suspected of causing 180°-rotated text reads.
///
/// Channel: `recycled_sound/vision_ocr`
///
/// Methods:
///   setCustomWords(words: [String]) → null
///     Cache the bias list so we don't re-pass it on every frame.
///   recognizeText(bytes, width, height, bytesPerRow, orientation)
///     → [{text, confidence, x, y, width, height}]
///     Run VNRecognizeTextRequest with .fast level, no language
///     correction, the cached customWords. Bounding boxes are in
///     Vision's normalised coords (0..1, origin bottom-left).
class VisionOcrPlugin: NSObject {
    private var channel: FlutterMethodChannel?
    private var customWords: [String] = []

    /// Run OCR off the platform channel thread so we don't block other
    /// channel calls (Object Capture, image picker) while a frame is
    /// being recognized.
    private let workQueue = DispatchQueue(
        label: "co.enspyr.recycledsound.vision_ocr",
        qos: .userInitiated
    )

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let channel = FlutterMethodChannel(
            name: "recycled_sound/vision_ocr",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.channel = channel
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setCustomWords":
            guard let args = call.arguments as? [String: Any],
                  let words = args["words"] as? [String] else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "setCustomWords requires words: [String]",
                    details: nil
                ))
                return
            }
            customWords = words
            result(nil)

        case "recognizeText":
            handleRecognize(call: call, result: result)

        case "recognizeFile":
            handleRecognizeFile(call: call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// OCR a still image already on disk (a captured brand-label shot), rather
    /// than a live camera frame. Loads via CGImageSource so EXIF orientation is
    /// honored — phone JPEGs are typically orient=6, and ignoring it yields zero
    /// tokens (a 2026-06-18 spike bug). Off the camera hot path, so the caller
    /// should pass accurate:true (.accurate reads labels .fast misses).
    private func handleRecognizeFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "BAD_ARGS",
                message: "recognizeFile requires path: String",
                details: nil
            ))
            return
        }
        let accurate = args["accurate"] as? Bool ?? true
        let wordsForFrame = self.customWords

        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard let src = CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOAD_FAIL",
                        message: "Failed to load image at \(path)",
                        details: nil
                    ))
                }
                return
            }
            // Read the embedded EXIF orientation; default .up if absent.
            var cgOrientation: CGImagePropertyOrientation = .up
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                    as? [CFString: Any],
               let raw = props[kCGImagePropertyOrientation] as? UInt32,
               let parsed = CGImagePropertyOrientation(rawValue: raw) {
                cgOrientation = parsed
            }
            self.runRecognition(
                cgImage: cgImage,
                orientation: cgOrientation,
                customWords: wordsForFrame,
                accurate: accurate,
                result: result
            )
        }
    }

    private func handleRecognize(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              let bytesPerRow = args["bytesPerRow"] as? Int,
              let orientationRaw = args["orientation"] as? Int else {
            result(FlutterError(
                code: "BAD_ARGS",
                message: "recognizeText requires bytes/width/height/bytesPerRow/orientation",
                details: nil
            ))
            return
        }

        // Snapshot the bias list before crossing threads — if the Flutter
        // side updates customWords mid-frame, we want this frame to see
        // the value at the time of the call, not a torn read.
        let wordsForFrame = self.customWords

        // Recognition level is caller-chosen. The LIVE per-frame path passes
        // false (.fast) — it runs on the camera hot path where throughput is
        // sacred. Off-hot-path STILL OCR (post-capture identify) should pass
        // true (.accurate): a 2026-06-18 spike showed .accurate reads brand
        // labels off captured stills that .fast misses entirely. Default false
        // so an omitted arg can never silently regress the live path.
        let accurate = args["accurate"] as? Bool ?? false

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.performRecognition(
                bytes: bytes,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                orientationRaw: orientationRaw,
                customWords: wordsForFrame,
                accurate: accurate,
                result: result
            )
        }
    }

    private func performRecognition(
        bytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        orientationRaw: Int,
        customWords: [String],
        accurate: Bool,
        result: @escaping FlutterResult
    ) {
        // Build a CGImage from the BGRA8888 byte buffer the camera
        // plugin handed us. premultipliedFirst + byteOrder32Little is
        // the canonical interpretation for AVFoundation BGRA output.
        guard let provider = CGDataProvider(data: bytes as CFData) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "PROVIDER_FAIL",
                    message: "Failed to create CGDataProvider from bytes",
                    details: nil
                ))
            }
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ]

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "CGIMAGE_FAIL",
                    message: "Failed to construct CGImage from BGRA bytes",
                    details: nil
                ))
            }
            return
        }

        // Map sensor orientation (degrees clockwise from upright) to
        // CGImagePropertyOrientation, which describes where the "top"
        // of the image is when read by Vision.
        //
        //   sensorOrientation=90  → .right (top is on the right side)
        //                            iPhone back camera in portrait
        //   sensorOrientation=270 → .left  (top is on the left)
        //                            iPhone front camera in some configs
        //   sensorOrientation=180 → .down  (upside down)
        //   sensorOrientation=0   → .up    (already upright)
        let cgOrientation: CGImagePropertyOrientation
        switch orientationRaw {
        case 90:  cgOrientation = .right
        case 180: cgOrientation = .down
        case 270: cgOrientation = .left
        default:  cgOrientation = .up
        }

        runRecognition(
            cgImage: cgImage,
            orientation: cgOrientation,
            customWords: customWords,
            accurate: accurate,
            result: result
        )
    }

    /// Shared Vision OCR core: build + perform a VNRecognizeTextRequest on a
    /// CGImage, marshal the results back to Flutter. Both the live-frame
    /// (bytes) and the still-file (path) entry points funnel through here so
    /// the recognition config stays identical between them.
    private func runRecognition(
        cgImage: CGImage,
        orientation cgOrientation: CGImagePropertyOrientation,
        customWords: [String],
        accurate: Bool,
        result: @escaping FlutterResult
    ) {
        let request = VNRecognizeTextRequest { (request, error) in
            if let error = error {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "RECOGNIZE_FAIL",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
                return
            }
            let observations =
                (request.results as? [VNRecognizedTextObservation]) ?? []
            let blocks: [[String: Any]] = observations.compactMap { obs in
                guard let candidate = obs.topCandidates(1).first else {
                    return nil
                }
                // Vision's boundingBox is normalized 0..1 with origin at
                // BOTTOM-LEFT — the Dart side flips to top-left to match
                // ML Kit conventions.
                return [
                    "text": candidate.string,
                    "confidence": candidate.confidence,
                    "x": obs.boundingBox.origin.x,
                    "y": obs.boundingBox.origin.y,
                    "width": obs.boundingBox.size.width,
                    "height": obs.boundingBox.size.height,
                ]
            }
            DispatchQueue.main.async {
                result(blocks)
            }
        }

        // .fast is the speed-optimised path; .accurate uses a heavier model.
        // .fast + customWords bias is the right tradeoff ON THE LIVE HOT PATH
        // (per-frame, throughput-sacred). But for off-hot-path still OCR the
        // 2026-06-18 spike found .accurate reads labels .fast misses entirely
        // (e.g. "Resouno"→ReSound where .fast returned nothing). Caller picks.
        request.recognitionLevel = accurate ? .accurate : .fast
        // Language correction is *bad* for product/model names — it
        // would push "Moxi" toward "Moxie" or similar. Off.
        request.usesLanguageCorrection = false
        // customWords requires iOS 16+. The app's deployment target
        // is iOS 17 (for Object Capture) so this is unconditionally safe.
        request.customWords = customWords
        // minimumTextHeight is fraction of image height. Default ~0.03
        // skips tiny text — hearing-aid stamps ARE tiny, so we lower it.
        // 0.01 corresponds to ~12px in a 1280-tall frame.
        request.minimumTextHeight = 0.01

        do {
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: cgOrientation,
                options: [:]
            )
            try handler.perform([request])
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "PERFORM_FAIL",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }
}
