//
//  PanoramaDetailView.swift
//  openpano
//
//  Immersive 360° viewer: look around with gyro or finger, save, and share.
//

import SwiftUI
import Photos
import MapKit
import CoreLocation

struct PanoramaDetailView: View {
    let panorama: Panorama

    @State private var image: UIImage?
    @State private var gyroEnabled = false
    @State private var showShare = false
    @State private var showSavedAlert = false
    @State private var saveError: String?
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                PanoramaSphereView(image: image, gyroEnabled: gyroEnabled)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            // Controls overlay
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    gyroToggle
                    Spacer()
                    saveButton
                    shareButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.white)
                }
            }
        }
        .task(id: panorama.id) {
            image = await loadImage()
        }
        .sheet(isPresented: $showShare) {
            if let image {
                ShareSheet(items: [image])
            }
        }
        .sheet(isPresented: $showInfo) {
            PanoramaInfoSheet(panorama: panorama)
        }
        .alert("Saved to Photos", isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: .constant(saveError != nil)) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // Shows the mode you'll switch *to*, so the icon doubles as a hint.
    private var gyroToggle: some View {
        Button {
            gyroEnabled.toggle()
        } label: {
            Label(gyroEnabled ? "Finger" : "Gyro",
                  systemImage: gyroEnabled ? "hand.draw" : "gyroscope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
        }
    }

    private var saveButton: some View {
        Button {
            saveToAlbum()
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: Circle())
        }
        .disabled(image == nil)
    }

    private var shareButton: some View {
        Button {
            showShare = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: Circle())
        }
        .disabled(image == nil)
    }

    private func saveToAlbum() {
        let fileURL = panorama.url
        let coordinate = panorama.coordinate
        let createdAt = panorama.createdAt

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveError = "Photo library access was denied." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                // Add the original file so its EXIF/GPS metadata is preserved,
                // and set the asset's location/date explicitly for Photos & Maps.
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: fileURL, options: nil)
                if let coordinate {
                    request.location = CLLocation(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude)
                }
                request.creationDate = createdAt
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        showSavedAlert = true
                    } else {
                        saveError = error?.localizedDescription ?? "Failed to save panorama."
                    }
                }
            }
        }
    }

    private func loadImage() async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            panorama.loadFullImage()
        }.value
    }
}

// MARK: - Native Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Info Sheet (map + date)

struct PanoramaInfoSheet: View {
    let panorama: Panorama

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?
    @State private var placeName: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if let coordinate = panorama.coordinate {
                ZStack(alignment: .bottom) {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))) {
                        Annotation("", coordinate: coordinate) {
                            pin
                        }
                    }
                    .ignoresSafeArea()

                    captionOverlay
                }
            } else {
                VStack(spacing: 0) {
                    ContentUnavailableView(
                        "No Location",
                        systemImage: "mappin.slash",
                        description: Text("This panorama has no saved location.")
                    )
                    .frame(maxHeight: .infinity)

                    Text(Self.dateFormatter.string(from: panorama.createdAt))
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .presentationDragIndicator(.visible)
        .task {
            thumbnail = await Task.detached(priority: .userInitiated) {
                downsampledImage(at: panorama.url, maxPixelSize: 240)
            }.value
        }
        .task {
            placeName = await PlaceNameResolver.resolve(latitude: panorama.latitude,
                                                        longitude: panorama.longitude)
        }
    }

    /// Date (and place name) overlaid on the map with a directional dim so the
    /// text stays legible over the map tiles.
    private var captionOverlay: some View {
        VStack(spacing: 6) {
            if let placeName {
                Text(placeName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(Self.dateFormatter.string(from: panorama.createdAt))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.bottom, 36)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var pin: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.3))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white, lineWidth: 3)
        )
        .shadow(radius: 4)
    }
}
