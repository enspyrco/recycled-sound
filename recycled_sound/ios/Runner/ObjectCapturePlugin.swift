import Flutter
import UIKit
import SwiftUI
import RealityKit
@preconcurrency import _RealityKit_SwiftUI
import ARKit

/// Flutter platform channel for Apple's Object Capture API.
///
/// Provides LiDAR-based 3D scanning of hearing aids. The session captures
/// images from multiple angles, then reconstructs a USDZ 3D model.
///
/// Requires iOS 17.0+ and a LiDAR-equipped device.
@available(iOS 17.0, *)
@MainActor
class ObjectCapturePlugin {
    private var channel: FlutterMethodChannel?
    private var session: ObjectCaptureSession?
    private var captureDir: URL?
    private var stateTask: Task<Void, Never>?
    private var shotsTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private let messenger: FlutterBinaryMessenger
    private var viewFactoryRegistered = false

    nonisolated init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        let channel = FlutterMethodChannel(
            name: "recycled_sound/object_capture",
            binaryMessenger: messenger
        )
        Task { @MainActor in
            self.channel = channel
            channel.setMethodCallHandler { [weak self] call, result in
                Task { @MainActor in
                    self?.handle(call, result: result)
                }
            }
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(ObjectCaptureSession.isSupported)

        case "startSession":
            startSession(result: result)

        case "startCapture":
            startCapture(result: result)

        case "getState":
            result(session.map { stateString($0.state) } ?? "idle")

        case "finish":
            finishSession(result: result)

        case "cancel":
            cancelSession(result: result)

        case "getModelPath":
            result(captureDir?.path)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startSession(result: @escaping FlutterResult) {
        guard ObjectCaptureSession.isSupported else {
            result(FlutterError(
                code: "NOT_SUPPORTED",
                message: "Object Capture is not supported on this device",
                details: nil
            ))
            return
        }

        // Create output directory
        let documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let dir = documentsDir.appendingPathComponent(
            "object_capture_\(Int(Date().timeIntervalSince1970))"
        )
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        captureDir = dir

        let session = ObjectCaptureSession()
        self.session = session

        // Register the native ObjectCaptureView as a Flutter platform view
        if !viewFactoryRegistered, let registrar = ObjectCapturePluginRegistrar.flutterRegistrar {
            let factory = ObjectCaptureViewFactory(session: session)
            registrar.register(factory, withId: "object-capture-view")
            viewFactoryRegistered = true
        }

        // Observe state via async sequence
        stateTask = Task { [weak self] in
            for await state in session.stateUpdates {
                guard let self = self else { return }
                self.channel?.invokeMethod("onStateChanged", arguments: [
                    "state": self.stateString(state),
                ])
                if case .completed = state {
                    self.channel?.invokeMethod("onModelReady", arguments: [
                        "path": self.captureDir?.path ?? "",
                    ])
                }
            }
        }

        // Observe shot count
        shotsTask = Task { [weak self] in
            for await count in session.numberOfShotsTakenUpdates {
                self?.channel?.invokeMethod("onProgress", arguments: [
                    "shotsTaken": count,
                ])
            }
        }

        // Observe feedback/guidance
        feedbackTask = Task { [weak self] in
            for await feedbackSet in session.feedbackUpdates {
                guard let self = self else { return }
                let text = feedbackSet.map { self.feedbackString($0) }.joined(separator: ". ")
                self.channel?.invokeMethod("onGuidance", arguments: [
                    "guidance": text.isEmpty ? "Slowly orbit the object" : text,
                ])
            }
        }

        // Start the session
        var config = ObjectCaptureSession.Configuration()
        config.isOverCaptureEnabled = false
        session.start(imagesDirectory: dir, configuration: config)

        result(nil)
    }

    private func startCapture(result: @escaping FlutterResult) {
        guard let session = session else {
            result(FlutterError(code: "NO_SESSION", message: "No active session", details: nil))
            return
        }

        if session.canRequestImageCapture {
            session.requestImageCapture()
            result(nil)
        } else {
            result(FlutterError(
                code: "CANNOT_CAPTURE",
                message: "Session is not ready for capture",
                details: nil
            ))
        }
    }

    private func finishSession(result: @escaping FlutterResult) {
        guard let session = session else {
            result(FlutterError(code: "NO_SESSION", message: "No active session", details: nil))
            return
        }
        session.finish()
        result(nil)
        // State observer will report .completed or .failed
    }

    private func cancelSession(result: @escaping FlutterResult) {
        cleanup()
        result(nil)
    }

    private func cleanup() {
        session?.cancel()
        stateTask?.cancel()
        shotsTask?.cancel()
        feedbackTask?.cancel()
        session = nil
    }

    private nonisolated func stateString(_ state: ObjectCaptureSession.CaptureState) -> String {
        switch state {
        case .initializing: return "initializing"
        case .ready: return "ready"
        case .detecting: return "detecting"
        case .capturing: return "capturing"
        case .finishing: return "finishing"
        case .completed: return "completed"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private nonisolated func feedbackString(_ feedback: ObjectCaptureSession.Feedback) -> String {
        switch feedback {
        case .objectTooClose: return "Move further away"
        case .objectTooFar: return "Move closer"
        case .movingTooFast: return "Slow down"
        case .objectNotFlippable: return "Flip the object"
        case .environmentLowLight: return "Need more light"
        case .environmentTooDark: return "Too dark"
        case .outOfFieldOfView: return "Object out of view"
        case .objectNotDetected: return "Point at the hearing aid"
        @unknown default: return "Keep going"
        }
    }
}

/// Register the plugin with the Flutter engine.
class ObjectCapturePluginRegistrar {
    /// Stored so the plugin can register platform view factories later.
    static var flutterRegistrar: FlutterPluginRegistrar?

    static func register(with messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar? = nil) {
        flutterRegistrar = registrar
        if #available(iOS 17.0, *) {
            _ = ObjectCapturePlugin(messenger: messenger)
        }
    }
}
