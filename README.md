# openpano

An open-source iOS app for capturing and viewing 360° equirectangular panoramas.

It uses **ARKit** to guide a multi-row capture and projects the photos onto an
equirectangular canvas using camera pose data — **no feature-matching or OpenCV
required**. Captured panoramas are viewed inside a **SceneKit** sphere that you
can explore with the gyroscope or by dragging.

## Features

- **Gallery** — a grid of every panorama you've captured, with a **Create Pano**
  button. Long-press a thumbnail to delete it.
- **Guided capture** — ARKit-driven aiming reticle walks you through three rows
  (level, up, down) of overlapping photos, then projects them into a 4096×2048
  equirectangular image.
- **Immersive viewer** — look around a panorama on the inside of a sphere.
  Toggle between **gyroscope** and **finger drag** control.
- **Share** — export any panorama through the native iOS share sheet.

## Architecture

| File | Role |
| --- | --- |
| `Panorama360CaptureView.swift` | ARKit guided multi-row capture UI |
| `EquirectangularProjector.swift` | Sensor-based equirectangular projection engine |
| `PanoramaSphereView.swift` | SceneKit sphere viewer (gyro + drag) |
| `PanoramaDetailView.swift` | Viewer chrome: gyro toggle + share |
| `PanoramaGalleryView.swift` | Grid + navigation |
| `PanoramaStore.swift` | On-disk persistence (JPEG in Documents) |

## Requirements

- iOS 26.2+
- A device with a rear camera and gyroscope (capture needs ARKit; it does not
  run in the Simulator). The viewer's gyro mode needs a real device too.

## Build

Open `openpano.xcodeproj` in Xcode, select your device, and run. Set your own
development team and bundle identifier in the target's signing settings.

## How capture works

1. Hold the phone in landscape and slowly rotate to fill the reticle ring at
   each target angle. The app captures automatically when you hold steady.
2. After the level row, it advances to the up and down rows.
3. Tap **Done** any time after two photos to finish early, or complete all rows.
4. The captured frames are inverse-mapped onto a sphere: for each output pixel
   the projector finds the best-facing source image (weighted by angle and edge
   distance) and blends overlapping contributions.

## License

MIT — see [LICENSE](LICENSE).
