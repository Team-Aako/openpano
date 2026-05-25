//
//  PanoramaGalleryView.swift
//  openpano
//
//  Date-grouped list of captured panoramas with a bottom "Capture panorama"
//  button. Tapping a panorama opens the immersive viewer; capturing a new one
//  navigates straight to it.
//

import SwiftUI
import CoreLocation

struct PanoramaGalleryView: View {
    @State private var store = PanoramaStore()
    @State private var path: [Route] = []
    @State private var showAbout = false

    private enum Route: Hashable {
        case capture
        case viewer(Panorama)
    }

    private struct DateSection: Identifiable {
        let id: Date
        let title: String
        let items: [Panorama]
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        if store.panoramas.isEmpty {
                            emptyState
                        } else {
                            ForEach(sections) { section in
                                sectionView(section)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 120) // clear the floating Capture button
                }

                captureButton
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .capture:
                    Panorama360CaptureView { image, coordinate in
                        if let pano = store.add(image: image, coordinate: coordinate) {
                            // Replace the capture screen with the viewer so
                            // "back" returns to the gallery.
                            path = [.viewer(pano)]
                        } else {
                            path.removeAll()
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .ignoresSafeArea()
                case .viewer(let pano):
                    PanoramaDetailView(panorama: pano)
                }
            }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            showAbout = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenPano")
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundStyle(.primary)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(height: 2)
                            .offset(y: 4)
                    }
                Text("\(store.panoramas.count) \(store.panoramas.count == 1 ? "PANORAMA" : "PANORAMAS")")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section

    private func sectionView(_ section: DateSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.secondary)

            ForEach(section.items) { pano in
                Button {
                    path.append(.viewer(pano))
                } label: {
                    PanoramaRow(panorama: pano)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        store.delete(pano)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Capture Button

    private var captureButton: some View {
        Button {
            path.append(.capture)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pano.fill")
                Text("Capture panorama")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.black))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
        .padding(.bottom, 40)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 80)
            Image(systemName: "pano")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No panoramas yet")
                .font(.title3.weight(.semibold))
            Text("Tap Capture panorama to make your first 360° scene.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Date Grouping

    private var sections: [DateSection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.panoramas) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return groups.keys.sorted(by: >).map { day in
            DateSection(id: day, title: sectionTitle(for: day), items: groups[day] ?? [])
        }
    }

    private func sectionTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "MMMM d" : "MMMM d, yyyy"
        return formatter.string(from: day).uppercased()
    }
}

// MARK: - Row

private struct PanoramaRow: View {
    let panorama: Panorama
    @State private var image: UIImage?
    @State private var locationText: String?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // Zoom in so the equirectangular poles (top/bottom
                        // black bands) fall outside the banner crop.
                        .scaleEffect(1.3)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 22))

            HStack {
                Text(Self.timeFormatter.string(from: panorama.createdAt))
                Spacer()
                if let locationText {
                    Text(locationText)
                }
            }
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .task(id: panorama.id) {
            image = await Task.detached(priority: .userInitiated) {
                downsampledImage(at: panorama.url, maxPixelSize: 1200)
            }.value
        }
        .task(id: panorama.id) {
            locationText = await PlaceNameResolver.resolve(latitude: panorama.latitude,
                                                           longitude: panorama.longitude)
        }
    }
}

// MARK: - Reverse Geocoding

enum PlaceNameResolver {
    private static var cache: [String: String] = [:]

    /// Resolves a "City, Country" name for a coordinate, falling back to raw
    /// lat/lon if geocoding is unavailable. Returns nil when there's no location.
    static func resolve(latitude: Double?, longitude: Double?) async -> String? {
        guard let latitude, let longitude else { return nil }
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return cached }

        let raw = String(format: "%.4f, %.4f", latitude, longitude)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let resolved: String
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let city = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
            let country = placemark.country
            switch (city, country) {
            case let (city?, country?): resolved = "\(city), \(country)"
            case let (city?, nil): resolved = city
            case let (nil, country?): resolved = country
            default: resolved = raw
            }
        } else {
            resolved = raw
        }
        cache[key] = resolved
        return resolved
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                    Text("OpenPano")
                        .font(.system(size: 40, weight: .heavy))

                    Text("An open-source iOS app for capturing and viewing 360° equirectangular panoramas developed by Aako, Inc.")
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)

                    HStack(spacing: 12) {
                        linkChip("GitHub", url: "https://github.com/aako-world/openpano")
                        linkChip("Aako", url: "https://aako.world")
                    }

                    Divider().padding(.vertical, 4)

                    Text("HOW IT WORKS")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.secondary)

                    step("01", "Capture", "ARKit guides you across three rows of overlapping photos, tracking camera pose in real time.")
                    Divider()
                    step("02", "Project", "Frames are projected onto an equirectangular sphere using pose data — no feature matching required.")
                    Divider()
                    step("03", "View", "Explore with the gyroscope or by dragging, then save or share the result.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }

    private func linkChip(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.black))
        }
    }

    private func step(_ number: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                Text(description)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
