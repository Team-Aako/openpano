//
//  PanoramaSphereView.swift
//  openpano
//
//  Renders an equirectangular panorama on the inside of a sphere and lets the
//  user look around with either the device gyroscope or a drag gesture.
//

import SwiftUI
import SceneKit
import CoreMotion
import simd

struct PanoramaSphereView: UIViewRepresentable {
    let image: UIImage
    /// When true, the camera is driven by the device gyroscope; otherwise by drag.
    var gyroEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.antialiasingMode = .multisampling2X

        let scene = SCNScene()
        view.scene = scene

        // Sphere with the panorama mapped onto its inside surface.
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.cullMode = .front // we view from inside
        // Mirror horizontally so the scene reads the correct way round from inside.
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        sphere.firstMaterial = material
        scene.rootNode.addChildNode(SCNNode(geometry: sphere))

        // Camera at the centre of the sphere.
        let camera = SCNCamera()
        camera.fieldOfView = 80
        camera.zNear = 0.1
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3Zero
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        context.coordinator.cameraNode = cameraNode

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        view.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.setGyro(enabled: gyroEnabled)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopGyro()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var cameraNode: SCNNode?
        weak var panGesture: UIPanGestureRecognizer?

        private let motionManager = CMMotionManager()
        private var gyroActive = false

        // Drag-driven orientation (radians).
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var lastTranslation: CGPoint = .zero

        // MARK: Gyro

        func setGyro(enabled: Bool) {
            if enabled {
                startGyro()
            } else {
                stopGyro()
                applyDragOrientation()
            }
            panGesture?.isEnabled = !enabled
        }

        private func startGyro() {
            guard !gyroActive, motionManager.isDeviceMotionAvailable else { return }
            gyroActive = true
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryZVertical,
                to: .main
            ) { [weak self] motion, _ in
                guard let self, let motion, let cameraNode = self.cameraNode else { return }

                // CoreMotion attitude maps the device frame into the reference
                // frame (Z up). SceneKit expects Y up, so pre-rotate the reference
                // frame by -90° about X to send the up-axis from Z to Y.
                let q = motion.attitude.quaternion
                let deviceQuat = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
                let tilt = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
                cameraNode.simdOrientation = tilt * deviceQuat
            }
        }

        func stopGyro() {
            guard gyroActive else { return }
            motionManager.stopDeviceMotionUpdates()
            gyroActive = false

            // Seed the drag orientation from where the gyro left off so toggling
            // back to finger mode doesn't snap the view.
            if let node = cameraNode {
                let e = node.eulerAngles
                pitch = max(-.pi / 2, min(.pi / 2, e.x))
                yaw = e.y
            }
        }

        // MARK: Drag

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !gyroActive, let view = gesture.view else { return }
            let translation = gesture.translation(in: view)

            switch gesture.state {
            case .began:
                lastTranslation = .zero
            case .changed:
                let dx = Float(translation.x - lastTranslation.x)
                let dy = Float(translation.y - lastTranslation.y)
                lastTranslation = translation

                // Scale drag distance to rotation; tuned for a natural feel.
                let factor: Float = 0.00375
                yaw += dx * factor
                pitch += dy * factor
                pitch = max(-.pi / 2, min(.pi / 2, pitch))
                applyDragOrientation()
            default:
                break
            }
        }

        private func applyDragOrientation() {
            cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
        }
    }
}
