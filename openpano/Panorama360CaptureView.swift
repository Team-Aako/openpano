//
//  Panorama360CaptureView.swift
//  openpano
//
//  Multi-row equirectangular 360° panorama capture with 3-axis guided aiming.
//  Captures 3 rows (middle, top, bottom) and projects them onto an
//  equirectangular canvas using ARKit sensor data (no feature matching).
//

import SwiftUI
import RealityKit
import ARKit
import CoreImage
import CoreLocation

// MARK: - Capture Row

enum CaptureRow: Int, CaseIterable {
    case middle = 0
    case top = 1
    case bottom = 2

    var targetPitch: Float {
        switch self {
        case .middle: return 0
        case .top: return .pi / 4       // +45°
        case .bottom: return -.pi / 4   // -45°
        }
    }

    var photoCount: Int {
        switch self {
        case .middle: return 12
        case .top, .bottom: return 8
        }
    }

    var yawInterval: Float {
        switch self {
        case .middle: return .pi / 6    // 30°
        case .top, .bottom: return .pi / 4  // 45°
        }
    }

    var pitchTolerance: Float { 0.17 } // ~10°

    var displayName: String {
        switch self {
        case .middle: return "Level"
        case .top: return "Up"
        case .bottom: return "Down"
        }
    }

    /// Capture order: middle first, then top, then bottom
    static var captureOrder: [CaptureRow] { [.middle, .top, .bottom] }

    var nextRow: CaptureRow? {
        switch self {
        case .middle: return .top
        case .top: return .bottom
        case .bottom: return nil
        }
    }

    var rowIndex: Int {
        Self.captureOrder.firstIndex(of: self)! + 1
    }
}

// MARK: - Main View

struct Panorama360CaptureView: View {
    /// Called with the finished equirectangular panorama image and the
    /// coordinate where it was captured (if location was available).
    var onComplete: (UIImage, CLLocationCoordinate2D?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let projector = EquirectangularProjector()
    @State private var location = LocationProvider()

    // Multi-row capture state
    @State private var photosByRow: [CaptureRow: [CapturedPhoto]] = [
        .middle: [], .top: [], .bottom: []
    ]
    @State private var referenceYawByRow: [CaptureRow: Float] = [:]
    @State private var lastCaptureYaw: Float?
    @State private var activeRow: CaptureRow = .middle
    @State private var completedRows: Set<CaptureRow> = []

    // Orientation state
    @State private var currentYaw: Float = 0
    @State private var currentPitch: Float = 0
    @State private var currentRoll: Float = 0

    // Drift detection state
    @State private var referencePosition: simd_float3?
    @State private var isDrifting = false

    // Turn animation state
    @State private var turnAnimating = false

    // Aiming state
    @State private var isInCaptureZone = false
    @State private var captureProgress: Double = 0
    @State private var captureStartTime: Date?

    // Processing state
    @State private var isProcessing = false
    @State private var processingPhase: String = ""
    @State private var projectionProgress: Double = 0
    @State private var showError = false
    @State private var errorMessage = ""

    // AR
    @State private var arSession: ARSession?
    @State private var currentFrame: ARFrame?

    private let captureFeedback = UIImpactFeedbackGenerator(style: .rigid)
    private let successFeedback = UINotificationFeedbackGenerator()

    // Configuration
    private let captureThreshold: Float = 0.17  // ~10° tolerance for capture zone
    private let rollTolerance: Float = 0.26     // ~15° max roll deviation
    private let captureDelay: Double = 0.5      // Hold time before capture

    // Computed helpers for active row
    private var activePhotos: [CapturedPhoto] {
        photosByRow[activeRow] ?? []
    }

    private var totalPhotoCount: Int {
        photosByRow.values.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        ZStack {
            if isProcessing {
                // Camera feed is no longer needed — tear it down so projection
                // gets the CPU/GPU, and just show a blank loading background.
                Color(.systemBackground).ignoresSafeArea()
                processingOverlay
            } else {
                CameraPreviewView(
                    onSessionReady: { session in arSession = session },
                    onFrameUpdate: { frame in
                        currentFrame = frame
                        updateOrientation(frame: frame)
                    }
                )
                .ignoresSafeArea()

                captureOverlay
            }
        }
        .alert("Stitching Failed", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    // MARK: - Captured Photo

    struct CapturedPhoto: Identifiable {
        let id = UUID()
        let image: UIImage              // 800px thumbnail for UI
        let rawCGImage: CGImage         // full-res raw (no orientation rotation)
        let cameraTransform: simd_float4x4  // ARFrame.camera.transform
        let intrinsics: simd_float3x3       // ARFrame.camera.intrinsics
        let imageResolution: CGSize         // ARFrame.camera.imageResolution
        let yaw: Float
        let pitch: Float
        let row: CaptureRow
        let captureOrder: Int
    }

    // MARK: - Computed Properties

    private var referenceYaw: Float? {
        referenceYawByRow[activeRow]
    }

    private var rotationFromStart: Float {
        guard let refYaw = referenceYaw else { return 0 }
        var delta = currentYaw - refYaw
        while delta < 0 { delta += .pi * 2 }
        while delta >= .pi * 2 { delta -= .pi * 2 }
        return delta
    }

    private var progress: Double {
        Double(activePhotos.count) / Double(activeRow.photoCount)
    }

    private var nextCaptureAngle: Float? {
        guard activePhotos.count < activeRow.photoCount else { return nil }
        guard let refYaw = referenceYaw else { return nil }

        let targetRotation = Float(activePhotos.count) * activeRow.yawInterval
        var targetYaw = refYaw + targetRotation
        while targetYaw >= .pi { targetYaw -= .pi * 2 }
        while targetYaw < -.pi { targetYaw += .pi * 2 }
        return targetYaw
    }

    private var distanceToNextCapture: Float {
        guard let target = nextCaptureAngle else { return .pi }
        var delta = target - currentYaw
        while delta > .pi { delta -= .pi * 2 }
        while delta < -.pi { delta += .pi * 2 }
        return delta
    }

    // MARK: - Orientation Tracking

    private func updateOrientation(frame: ARFrame) {
        let transform = frame.camera.transform
        let forward = -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        let yaw = atan2(forward.x, -forward.z)
        let pitch = asin(forward.y)

        // Roll calculation
        let cameraUp = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let worldUp = simd_float3(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, worldUp))
        let expectedUp = simd_cross(right, forward)
        let roll = atan2(simd_dot(cameraUp, right), simd_dot(cameraUp, expectedUp))

        self.currentYaw = yaw
        self.currentPitch = pitch
        self.currentRoll = roll

        // Track translation drift from starting position
        let position = simd_float3(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        if let ref = referencePosition {
            isDrifting = simd_distance(position, ref) > 0.08  // 8cm threshold
        }

        checkCaptureZone()
    }

    private func checkCaptureZone() {
        let pitchDelta = abs(currentPitch - activeRow.targetPitch)
        let pitchOK = pitchDelta < activeRow.pitchTolerance
        let rollOK = abs(currentRoll) < rollTolerance

        // First photo in this row: ready if pitch and roll OK
        if activePhotos.isEmpty {
            updateCaptureState(inZone: pitchOK && rollOK)
            return
        }

        // Subsequent photos: also check yaw
        guard let _ = nextCaptureAngle else {
            updateCaptureState(inZone: false)
            return
        }

        let angleOK = abs(distanceToNextCapture) < captureThreshold
        updateCaptureState(inZone: angleOK && pitchOK && rollOK)
    }

    private func updateCaptureState(inZone: Bool) {
        if inZone {
            if !isInCaptureZone {
                isInCaptureZone = true
                captureStartTime = Date()
            }

            if let startTime = captureStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                captureProgress = min(elapsed / captureDelay, 1.0)

                if captureProgress >= 1.0 {
                    performCapture()
                }
            }
        } else {
            isInCaptureZone = false
            captureProgress = 0
            captureStartTime = nil
        }
    }

    // MARK: - Capture

    private func performCapture() {
        guard let frame = currentFrame else { return }

        captureFeedback.impactOccurred(intensity: 1.0)

        let pixelBuffer = frame.capturedImage

        // 1. Oriented image for UI thumbnail (800px)
        let ciImageOriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let context = CIContext()
        guard let cgImageOriented = context.createCGImage(ciImageOriented, from: ciImageOriented.extent) else { return }
        let fullImage = UIImage(cgImage: cgImageOriented)
        let image = fullImage.resizeToFit(maxLength: 800)

        // 2. Raw CGImage (no orientation rotation) for projection
        let ciImageRaw = CIImage(cvPixelBuffer: pixelBuffer)
        guard let rawCGImage = context.createCGImage(ciImageRaw, from: ciImageRaw.extent) else { return }

        // 3. ARKit camera metadata
        let cameraTransform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        // Record reference position on first capture of the session
        if referencePosition == nil {
            let t = frame.camera.transform
            referencePosition = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        // Set reference yaw on first capture of this row
        if activePhotos.isEmpty {
            referenceYawByRow[activeRow] = currentYaw
        }

        lastCaptureYaw = currentYaw

        let photo = CapturedPhoto(
            image: image,
            rawCGImage: rawCGImage,
            cameraTransform: cameraTransform,
            intrinsics: intrinsics,
            imageResolution: imageResolution,
            yaw: currentYaw,
            pitch: currentPitch,
            row: activeRow,
            captureOrder: activePhotos.count
        )
        photosByRow[activeRow, default: []].append(photo)

        // Reset capture state
        isInCaptureZone = false
        captureProgress = 0
        captureStartTime = nil

        successFeedback.notificationOccurred(.success)

        // Check row completion
        if (photosByRow[activeRow]?.count ?? 0) >= activeRow.photoCount {
            completeCurrentRow()
        }
    }

    private func completeCurrentRow() {
        completedRows.insert(activeRow)

        if completedRows.count == CaptureRow.allCases.count {
            // All rows complete
            performMultiRowStitching()
        } else if let next = activeRow.nextRow {
            // Auto-advance to next row — pitch aiming UI will show in captureArcCenter
            activeRow = next
            lastCaptureYaw = nil
            isInCaptureZone = false
            captureProgress = 0
            captureStartTime = nil
        } else {
            performMultiRowStitching()
        }
    }

    // MARK: - UI Components

    private var isPanning: Bool { totalPhotoCount > 0 }

    @ViewBuilder
    private var captureOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                // Top bar — close + (optional) finish
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        Spacer()
                        if totalPhotoCount >= 2 {
                            Button(action: performEarlyFinish) {
                                Text("Done")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                    Spacer()
                }

                if isPanning {
                    // === Landscape capture layout ===

                    // Row counter — center top (in landscape: right edge center = top center)
                    Text("Row \(activeRow.rowIndex)/3")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Capsule())
                        .rotationEffect(.degrees(90))
                        .position(x: geometry.size.width - 36, y: geometry.size.height / 2)

                    // Yellow target capsule — moves with pitch toward center
                    if isPitchAimingMode {
                        let pitchDelta = currentPitch - activeRow.targetPitch
                        let t = CGFloat(min(abs(pitchDelta) / (Float.pi / 4), 1.0))
                        let edgeX = pitchDelta < 0 ? geometry.size.width - 60 : CGFloat(60)
                        let centerX = geometry.size.width / 2
                        let capsuleX = centerX + (edgeX - centerX) * t
                        Capsule()
                            .fill(Color.yellow.opacity(0.8))
                            .frame(width: 80, height: 18)
                            .rotationEffect(.degrees(90))
                            .position(x: capsuleX, y: geometry.size.height / 2)
                    }

                    // Center: arc with capture zone inside + direction arrow + guidance text
                    captureArcCenter
                        .rotationEffect(.degrees(90))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                } else {
                    // === Portrait layout (before first capture) ===
                    rotatePhonePrompt
                        .transition(.opacity)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: isPanning)
        }
    }

    /// Whether we're in pitch-aiming mode (pitch is outside tolerance for the active row)
    private var isPitchAimingMode: Bool {
        guard isPanning else { return false }
        let pitchDelta = abs(currentPitch - activeRow.targetPitch)
        return pitchDelta >= activeRow.pitchTolerance
    }

    /// Combined center element with two modes:
    /// - Capture mode: ring with dots, capture zone, direction arrows
    /// - Pitch-aiming mode: ring without dots, dashed target rect, moving yellow rect
    @ViewBuilder
    private var captureArcCenter: some View {
        let ringRadius: CGFloat = 90
        let rowPhotos = photosByRow[activeRow] ?? []
        let pitchDelta = currentPitch - activeRow.targetPitch

        ZStack {
            ZStack {
                // Single background ring (always visible)
                Circle()
                    .stroke(
                        isPitchAimingMode ? Color.yellow.opacity(0.2) : Color.white.opacity(0.3),
                        lineWidth: 4
                    )
                    .frame(width: ringRadius * 2, height: ringRadius * 2)

                if isPitchAimingMode {
                    // === Pitch-aiming mode ===

                    // Dashed white target capsule inside the ring
                    Capsule()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 80, height: 18)

                    // Vertical animated chevrons above/below ring
                    verticalTurnIndicator(pointUp: pitchDelta < 0)
                        .offset(y: pitchDelta < 0 ? -(ringRadius + 30) : (ringRadius + 30))
                } else {
                    // === Capture mode ===

                    // Completed arc between captured dots
                    if rowPhotos.count >= 2 {
                        Circle()
                            .trim(
                                from: 0,
                                to: Double(rowPhotos.count - 1) / Double(activeRow.photoCount)
                            )
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: ringRadius * 2, height: ringRadius * 2)
                            .rotationEffect(.degrees(180))
                    }

                    // Capture position dots on ring
                    ForEach(0..<activeRow.photoCount, id: \.self) { index in
                        let angle = Double(index) / Double(activeRow.photoCount) * 360 - 90
                        let isCaptured = index < rowPhotos.count

                        Circle()
                            .fill(isCaptured ? Color.yellow : Color.white.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .offset(y: -ringRadius)
                            .rotationEffect(.degrees(angle))
                    }

                    // Current position indicator on ring
                    if !activePhotos.isEmpty {
                        let currentAngle = Double(rotationFromStart / (.pi * 2)) * 360 - 90

                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
                            )
                            .offset(y: -ringRadius)
                            .rotationEffect(.degrees(currentAngle))
                    }

                    // Capture zone indicator inside the ring
                    Circle()
                        .stroke(
                            isInCaptureZone ? Color.yellow : Color.white.opacity(0.6),
                            lineWidth: 2
                        )
                        .frame(width: 60, height: 60)

                    // Capture progress ring
                    if captureProgress > 0 {
                        Circle()
                            .trim(from: 0, to: captureProgress)
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(90))
                    }

                    // Center crosshair dot
                    Circle()
                        .fill(isInCaptureZone ? Color.yellow : Color.white.opacity(0.8))
                        .frame(width: 8, height: 8)

                    // Direction arrow — positioned to the right of the ring
                    if !isInCaptureZone {
                        directionArrow
                            .offset(x: ringRadius + 50)
                    }
                }
            }

            // Guidance text below the ring — offset down from center
            Group {
                if isPitchAimingMode {
                    if activeRow == .middle {
                        Text("Level the phone")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    } else {
                        Text(activeRow == .top ? "Tilt phone up ~45\u{00B0}" : "Tilt phone down ~45\u{00B0}")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    bottomGuidance
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.7))
            )
            .offset(y: isPitchAimingMode ? ringRadius + 80 : ringRadius + 40)
        }
    }

    @ViewBuilder
    private var rotatePhonePrompt: some View {
        VStack(spacing: 80) {
            // Large rotate icon — mirrored right-to-left
            Image(systemName: "arrow.turn.up.forward.iphone.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundColor(.yellow)
                .scaleEffect(x: -1, y: 1)

            // Instruction text with inline phone icons
            HStack(spacing: 5) {
                Text("Rotate your phone left 90\u{00B0}, from")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "iphone")
                    .font(.system(size: 16))
                Text("to")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "iphone.landscape")
                    .font(.system(size: 16))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.7))
            )
        }
    }

    @ViewBuilder
    private var directionArrow: some View {
        let distance = distanceToNextCapture
        let rollOK = abs(currentRoll) < rollTolerance
        let pitchDelta = currentPitch - activeRow.targetPitch
        let pitchOK = abs(pitchDelta) < activeRow.pitchTolerance

        Group {
            // Priority 1: Roll
            if !rollOK {
                VStack(spacing: 4) {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 24, weight: .bold))
                    Text("Straighten phone")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.yellow)
            }
            // Priority 2: Pitch
            else if !pitchOK {
                VStack(spacing: 4) {
                    Image(systemName: pitchDelta > 0 ? "arrow.down" : "arrow.up")
                        .font(.system(size: 24, weight: .bold))
                    Text(pitchDelta > 0 ? "Tilt down" : "Tilt up")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.yellow)
            }
            // Priority 3: Yaw — animated chevrons
            else if abs(distance) > captureThreshold {
                turnIndicator(goRight: distance > 0)
            }
        }
    }

    @ViewBuilder
    private func turnIndicator(goRight: Bool) -> some View {
        HStack(spacing: 4) {
            if !goRight {
                animatedChevrons(pointRight: false)
            }
            if goRight {
                animatedChevrons(pointRight: true)
            }
        }
        .foregroundColor(.yellow)
        .onAppear {
            turnAnimating = false
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                turnAnimating = true
            }
        }
        .onDisappear {
            turnAnimating = false
        }
    }

    @ViewBuilder
    private func animatedChevrons(pointRight: Bool) -> some View {
        let symbol = pointRight ? "chevron.right" : "chevron.left"
        HStack(spacing: -2) {
            Image(systemName: symbol)
                .opacity(pointRight ? 1.0 : 0.3)
            Image(systemName: symbol)
                .opacity(0.6)
            Image(systemName: symbol)
                .opacity(pointRight ? 0.3 : 1.0)
        }
        .font(.system(size: 16, weight: .bold))
        .offset(x: turnAnimating ? (pointRight ? 5 : -5) : 0)
    }

    @ViewBuilder
    private func verticalTurnIndicator(pointUp: Bool) -> some View {
        let symbol = pointUp ? "chevron.up" : "chevron.down"
        VStack(spacing: -2) {
            Image(systemName: symbol)
                .opacity(pointUp ? 1.0 : 0.3)
            Image(systemName: symbol)
                .opacity(0.6)
            Image(systemName: symbol)
                .opacity(pointUp ? 0.3 : 1.0)
        }
        .font(.system(size: 16, weight: .bold))
        .foregroundColor(.yellow)
        .offset(y: turnAnimating ? (pointUp ? -5 : 5) : 0)
        .onAppear {
            turnAnimating = false
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                turnAnimating = true
            }
        }
        .onDisappear {
            turnAnimating = false
        }
    }

    @ViewBuilder
    private var bottomGuidance: some View {
        VStack(spacing: 8) {
            if activePhotos.isEmpty {
                Text("Hold steady to start \(activeRow.displayName.lowercased()) row")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            } else if activePhotos.count < activeRow.photoCount {
                if isInCaptureZone {
                    Text("Hold steady...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.yellow)
                } else {
                    Text("Turn slowly to the right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            } else {
                Text("Row complete!")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.yellow)
            }
        }
    }

    // MARK: - Processing Overlay

    @ViewBuilder
    private var processingOverlay: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    // Background ring
                    Circle()
                        .stroke(Color.black.opacity(0.1), lineWidth: 5)
                        .frame(width: 88, height: 88)

                    // Progress ring
                    Circle()
                        .trim(from: 0, to: projectionProgress)
                        .stroke(
                            Color.black,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 88, height: 88)
                        .rotationEffect(.degrees(90))
                        .animation(.linear(duration: 0.1), value: projectionProgress)

                    // Percentage
                    Text("\(Int(projectionProgress * 100))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }

                VStack(spacing: 8) {
                    Text(processingPhase)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)

                    Text("\(totalPhotoCount) photos")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func performEarlyFinish() {
        // Project whatever rows have 1+ photos
        if (photosByRow[activeRow]?.count ?? 0) >= 1 {
            completedRows.insert(activeRow)
        }
        performMultiRowStitching()
    }

    private func performMultiRowStitching() {
        let rowsToProject = CaptureRow.captureOrder.filter {
            (photosByRow[$0]?.count ?? 0) >= 1
        }
        guard !rowsToProject.isEmpty else { return }

        // Collect all captured photos from all rows into OrientedCapture array
        var captures: [OrientedCapture] = []
        for row in rowsToProject {
            let photos = (photosByRow[row] ?? [])
                .sorted { $0.captureOrder < $1.captureOrder }
            for photo in photos {
                captures.append(OrientedCapture(
                    cgImage: photo.rawCGImage,
                    cameraTransform: photo.cameraTransform,
                    intrinsics: photo.intrinsics,
                    imageResolution: photo.imageResolution
                ))
            }
        }

        performStandaloneStitching(captures: captures)
    }

    /// Show processing overlay, then hand the finished image back to the caller.
    private func performStandaloneStitching(captures: [OrientedCapture]) {
        // Stop AR updates while we crunch pixels.
        arSession?.pause()

        isProcessing = true
        projectionProgress = 0
        processingPhase = "Preparing images..."

        Task {
            processingPhase = "Projecting panorama..."

            // Animate progress alongside the real projection work
            let animationTask = Task { @MainActor in
                while !Task.isCancelled {
                    let remaining = 0.92 - projectionProgress
                    if remaining > 0.001 {
                        projectionProgress += remaining * 0.025
                    }
                    if projectionProgress > 0.85 {
                        processingPhase = "Almost there..."
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            // Run the heavy projection off the main actor. With approachable
            // concurrency, a bare `await projector.project(...)` would otherwise
            // execute on the caller's (Main) executor and freeze the UI.
            let projector = self.projector
            let finalImage = await Task.detached(priority: .userInitiated) {
                await projector.project(
                    captures: captures,
                    outputWidth: 4096,
                    outputHeight: 2048
                )
            }.value

            animationTask.cancel()

            // Show completion briefly before transitioning
            projectionProgress = 1.0
            processingPhase = "Done!"

            try? await Task.sleep(nanoseconds: 400_000_000)

            isProcessing = false

            if let image = finalImage {
                successFeedback.notificationOccurred(.success)
                onComplete(image, location.coordinate)
            } else {
                errorMessage = "Failed to project panorama."
                showError = true
            }
        }
    }
}

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let onSessionReady: (ARSession) -> Void
    let onFrameUpdate: (ARFrame) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []

        arView.session.run(config)
        arView.session.delegate = context.coordinator

        onSessionReady(arView.session)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFrameUpdate: onFrameUpdate)
    }

    class Coordinator: NSObject, ARSessionDelegate {
        let onFrameUpdate: (ARFrame) -> Void

        init(onFrameUpdate: @escaping (ARFrame) -> Void) {
            self.onFrameUpdate = onFrameUpdate
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            onFrameUpdate(frame)
        }
    }
}
