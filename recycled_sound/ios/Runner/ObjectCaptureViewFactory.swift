import Flutter
import SwiftUI
import UIKit
@preconcurrency import _RealityKit_SwiftUI

/// Factory that creates native ObjectCaptureView instances for Flutter.
@available(iOS 17.0, *)
class ObjectCaptureViewFactory: NSObject, FlutterPlatformViewFactory {
    private let session: ObjectCaptureSession

    init(session: ObjectCaptureSession) {
        self.session = session
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        ObjectCapturePlatformView(frame: frame, session: session)
    }
}

/// Wraps Apple's ObjectCaptureView (SwiftUI) as a FlutterPlatformView.
///
/// Shows the live camera with built-in object detection, point cloud
/// materializing on the surface, and guided orbit indicators.
@available(iOS 17.0, *)
class ObjectCapturePlatformView: NSObject, FlutterPlatformView {
    private let hostingController: UIHostingController<AnyView>

    init(frame: CGRect, session: ObjectCaptureSession) {
        let captureView = ObjectCaptureView(session: session)
        let wrappedView = AnyView(captureView)
        hostingController = UIHostingController(rootView: wrappedView)
        hostingController.view.frame = frame
        hostingController.view.backgroundColor = .black
        super.init()
    }

    func view() -> UIView {
        hostingController.view
    }
}
