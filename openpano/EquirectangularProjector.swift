//
//  EquirectangularProjector.swift
//  openpano
//
//  Sensor-based equirectangular projection engine.
//  Projects captured images onto an equirectangular canvas using ARKit
//  camera orientation data (no feature matching needed).
//

import UIKit
import simd
import Accelerate

private struct SendablePointer<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
}

// MARK: - Input Type

/// A single captured image with its ARKit camera pose and intrinsics.
/// Immutable value type holding an (effectively immutable) CGImage, so it is
/// safe to hand to a background executor for projection.
struct OrientedCapture: @unchecked Sendable {
    let cgImage: CGImage               // full-res raw (no orientation rotation)
    let cameraTransform: simd_float4x4 // ARFrame.camera.transform
    let intrinsics: simd_float3x3      // ARFrame.camera.intrinsics
    let imageResolution: CGSize        // ARFrame.camera.imageResolution
}

// MARK: - Projector

/// Projects oriented captures onto an equirectangular canvas using inverse mapping.
///
/// Algorithm (per output pixel):
///   1. Convert (px, py) → spherical (theta, phi) → world-space direction
///   2. For each capture, transform direction into camera space
///   3. Project onto image plane using intrinsics
///   4. Sample with bilinear interpolation, weighted by edge distance
///   5. Blend overlapping contributions
actor EquirectangularProjector {

    /// Projects all captures onto an equirectangular canvas.
    /// - Parameters:
    ///   - captures: Array of oriented captures with camera metadata.
    ///   - outputWidth: Canvas width in pixels (default 4096).
    ///   - outputHeight: Canvas height in pixels (default 2048).
    /// - Returns: Equirectangular UIImage (scale 1.0), or nil on failure.
    nonisolated func project(
        captures: [OrientedCapture],
        outputWidth: Int = 4096,
        outputHeight: Int = 2048
    ) async -> UIImage? {
        guard !captures.isEmpty else { return nil }

        // Pre-decode all images into raw pixel buffers for fast sampling
        let decodedCaptures = captures.compactMap { DecodedCapture(from: $0) }
        guard !decodedCaptures.isEmpty else { return nil }

        let W = outputWidth
        let H = outputHeight

        // Allocate output RGBA buffer
        let bytesPerPixel = 4
        let bytesPerRow = W * bytesPerPixel
        let bufferSize = H * bytesPerRow
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        outputBuffer.initialize(repeating: 0, count: bufferSize)

        // Accumulation buffers (weight per pixel for blending)
        let colorAccum = UnsafeMutablePointer<Float>.allocate(capacity: W * H * 3)
        let weightAccum = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
        let coverageAccum = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
        colorAccum.initialize(repeating: 0, count: W * H * 3)
        weightAccum.initialize(repeating: 0, count: W * H)
        coverageAccum.initialize(repeating: 0, count: W * H)

        // Pre-compute per-capture data
        let captureData = decodedCaptures.map { PrecomputedCapture(from: $0) }

        let wF = Float(W)
        let hF = Float(H)

        // Process rows in parallel
        let _colorAccum = SendablePointer(pointer: colorAccum)
        let _weightAccum = SendablePointer(pointer: weightAccum)
        let _coverageAccum = SendablePointer(pointer: coverageAccum)

        DispatchQueue.concurrentPerform(iterations: H) { py in
            let colorAccum = _colorAccum.pointer
            let weightAccum = _weightAccum.pointer
            let coverageAccum = _coverageAccum.pointer

            let phi = Float.pi / 2.0 - (Float(py) + 0.5) / hF * Float.pi  // latitude
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)

            for px in 0..<W {
                let theta = (Float(px) + 0.5) / wF * 2.0 * Float.pi - Float.pi  // longitude
                let sinTheta = sin(theta)
                let cosTheta = cos(theta)

                // World-space direction on unit sphere
                let dWorld = simd_float3(
                    cosPhi * sinTheta,
                    sinPhi,
                    cosPhi * cosTheta
                )

                var rSum: Float = 0
                var gSum: Float = 0
                var bSum: Float = 0
                var wSum: Float = 0
                var maxEdge: Float = 0

                for cap in captureData {
                    // Transform world direction to camera space
                    let dCam = cap.rotationTranspose * dWorld

                    // Camera looks along -Z; skip if point is behind camera
                    guard dCam.z < -1e-6 else { continue }

                    let invZ = -1.0 / dCam.z

                    // Project to pixel coordinates using intrinsics.
                    // ARKit camera space: +Y is up, but image +v is down,
                    // so negate Y when projecting to image coordinates.
                    let u = cap.fx * dCam.x * invZ + cap.cx
                    let v = -cap.fy * dCam.y * invZ + cap.cy

                    // Check bounds (with 0.5px margin for bilinear)
                    guard u >= 0.5, u < cap.widthF - 0.5,
                          v >= 0.5, v < cap.heightF - 0.5 else { continue }

                    // Bilinear interpolation
                    let (r, g, b) = cap.decoded.sampleBilinear(u: u, v: v)

                    // Angular weight: prefer the capture facing most directly at this direction
                    let cosAngle = simd_dot(dWorld, cap.opticalAxis)
                    let angularWeight = powf(max(cosAngle, 0), 32)

                    // Edge feathering: still needed to avoid sampling near image borders
                    let edgeX = min(u, cap.widthF - 1.0 - u) / cap.widthF
                    let edgeY = min(v, cap.heightF - 1.0 - v) / cap.heightF
                    let edgeDist = min(edgeX, edgeY)
                    let featherZone: Float = 0.15  // outer 15%
                    let edgeWeight = min(edgeDist / featherZone, 1.0)

                    let weight = angularWeight * edgeWeight

                    guard weight > 0 else { continue }

                    rSum += r * weight
                    gSum += g * weight
                    bSum += b * weight
                    wSum += weight
                    maxEdge = max(maxEdge, edgeWeight)
                }

                let pixelIndex = py * W + px

                if wSum > 0 {
                    colorAccum[pixelIndex * 3 + 0] = rSum
                    colorAccum[pixelIndex * 3 + 1] = gSum
                    colorAccum[pixelIndex * 3 + 2] = bSum
                    weightAccum[pixelIndex] = wSum
                    coverageAccum[pixelIndex] = maxEdge
                }
            }
        }

        // Normalize and write to output buffer
        let _outputBuffer = SendablePointer(pointer: outputBuffer)

        DispatchQueue.concurrentPerform(iterations: H) { py in
            let colorAccum = _colorAccum.pointer
            let weightAccum = _weightAccum.pointer
            let coverageAccum = _coverageAccum.pointer
            let outputBuffer = _outputBuffer.pointer

            for px in 0..<W {
                let pixelIndex = py * W + px
                let w = weightAccum[pixelIndex]
                let offset = pixelIndex * bytesPerPixel

                if w > 0 {
                    let invW = 1.0 / w
                    // Smooth fade to black at the fringe of coverage.
                    // Uses max edge proximity: high inside any capture, low only
                    // at the true boundary of total coverage (not between captures).
                    let fade = min(coverageAccum[pixelIndex] / 0.1, 1.0)
                    outputBuffer[offset + 0] = clampToUInt8(colorAccum[pixelIndex * 3 + 0] * invW * fade)
                    outputBuffer[offset + 1] = clampToUInt8(colorAccum[pixelIndex * 3 + 1] * invW * fade)
                    outputBuffer[offset + 2] = clampToUInt8(colorAccum[pixelIndex * 3 + 2] * invW * fade)
                }
                // All pixels opaque (uncovered = black)
                outputBuffer[offset + 3] = 255
            }
        }

        // Create CGImage from buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        let image: UIImage?
        if let context = CGContext(
            data: outputBuffer,
            width: W,
            height: H,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cgImage = context.makeImage() {
            image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        } else {
            image = nil
        }

        // Cleanup
        colorAccum.deallocate()
        weightAccum.deallocate()
        coverageAccum.deallocate()
        outputBuffer.deallocate()

        return image
    }
}

// MARK: - Decoded Capture (raw pixel data)

/// Holds decoded pixel data for fast bilinear sampling.
private final class DecodedCapture {
    let pixels: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize

    init?(from capture: OrientedCapture) {
        let cg = capture.cgImage
        self.width = cg.width
        self.height = cg.height
        self.bytesPerRow = width * 4
        self.cameraTransform = capture.cameraTransform
        self.intrinsics = capture.intrinsics
        self.imageResolution = capture.imageResolution

        let bufferSize = height * bytesPerRow
        self.pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            pixels.deallocate()
            return nil
        }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit {
        pixels.deallocate()
    }

    /// Bilinear interpolation sampling at fractional coordinates.
    /// Returns (R, G, B) as Float values in [0, 255].
    func sampleBilinear(u: Float, v: Float) -> (Float, Float, Float) {
        let x0 = Int(u)
        let y0 = Int(v)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)

        let fx = u - Float(x0)
        let fy = v - Float(y0)
        let fx1 = 1.0 - fx
        let fy1 = 1.0 - fy

        let w00 = fx1 * fy1
        let w10 = fx * fy1
        let w01 = fx1 * fy
        let w11 = fx * fy

        let p00 = y0 * bytesPerRow + x0 * 4
        let p10 = y0 * bytesPerRow + x1 * 4
        let p01 = y1 * bytesPerRow + x0 * 4
        let p11 = y1 * bytesPerRow + x1 * 4

        let r = Float(pixels[p00]) * w00 + Float(pixels[p10]) * w10 +
                Float(pixels[p01]) * w01 + Float(pixels[p11]) * w11
        let g = Float(pixels[p00 + 1]) * w00 + Float(pixels[p10 + 1]) * w10 +
                Float(pixels[p01 + 1]) * w01 + Float(pixels[p11 + 1]) * w11
        let b = Float(pixels[p00 + 2]) * w00 + Float(pixels[p10 + 2]) * w10 +
                Float(pixels[p01 + 2]) * w01 + Float(pixels[p11 + 2]) * w11

        return (r, g, b)
    }
}

// MARK: - Precomputed Capture Data

/// Pre-extracted rotation and intrinsics for inner-loop performance.
private struct PrecomputedCapture: @unchecked Sendable {
    let decoded: DecodedCapture
    let rotationTranspose: simd_float3x3
    let opticalAxis: simd_float3  // camera forward direction in world space
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let widthF: Float
    let heightF: Float

    init(from decoded: DecodedCapture) {
        self.decoded = decoded

        // Extract 3x3 rotation from 4x4 transform
        let t = decoded.cameraTransform
        let rotation = simd_float3x3(
            simd_float3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
            simd_float3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
            simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        )
        self.rotationTranspose = rotation.transpose

        // Camera forward = -Z in camera space → in world space = -R.column(2)
        let col2 = simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        self.opticalAxis = -col2

        // Intrinsics are for the full-resolution image.
        // Scale them to match the actual CGImage size (which may differ
        // from imageResolution if the raw capture was not rotated).
        let intrinsics = decoded.intrinsics
        let scaleX = Float(decoded.width) / Float(decoded.imageResolution.width)
        let scaleY = Float(decoded.height) / Float(decoded.imageResolution.height)

        self.fx = intrinsics[0][0] * scaleX
        self.fy = intrinsics[1][1] * scaleY
        self.cx = intrinsics[2][0] * scaleX
        self.cy = intrinsics[2][1] * scaleY

        self.widthF = Float(decoded.width)
        self.heightF = Float(decoded.height)
    }
}

// MARK: - Helpers

@inline(__always)
private func clampToUInt8(_ value: Float) -> UInt8 {
    return UInt8(max(0, min(255, value + 0.5)))
}
