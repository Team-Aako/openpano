//
//  PanoramaStore.swift
//  openpano
//
//  On-disk persistence for captured equirectangular panoramas.
//  Each panorama is a JPEG in Documents/Panoramas (named with its creation
//  timestamp and a UUID); capture coordinates live in a sidecar metadata.json.
//

import UIKit
import CoreLocation

/// A single saved panorama, backed by a JPEG file on disk.
struct Panorama: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    var latitude: Double?
    var longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (lhs: Panorama, rhs: Panorama) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Loads the full-resolution equirectangular image. Heavy — use only in the viewer.
    func loadFullImage() -> UIImage? {
        UIImage(contentsOfFile: url.path)
    }
}

@Observable
final class PanoramaStore {
    private(set) var panoramas: [Panorama] = []

    private let directory: URL
    private let metadataURL: URL

    private struct PanoMeta: Codable {
        var latitude: Double?
        var longitude: Double?
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Panoramas", isDirectory: true)
        metadataURL = directory.appendingPathComponent("metadata.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    /// Rebuilds the in-memory list from disk, newest first.
    func reload() {
        let metas = loadMetadata()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        panoramas = files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { url -> Panorama in
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: "_").last ?? "") ?? UUID()
                let meta = metas[id.uuidString]
                return Panorama(id: id, url: url, createdAt: creationDate(of: url),
                                latitude: meta?.latitude, longitude: meta?.longitude)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Persists a freshly stitched panorama and returns its model.
    @discardableResult
    func add(image: UIImage, coordinate: CLLocationCoordinate2D? = nil) -> Panorama? {
        let createdAt = Date()
        guard let data = jpegDataWithMetadata(image, coordinate: coordinate, date: createdAt, quality: 0.9) else { return nil }
        let id = UUID()
        let timestamp = Int(createdAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("\(timestamp)_\(id.uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PanoramaStore] Failed to write panorama: \(error)")
            return nil
        }
        let panorama = Panorama(id: id, url: url, createdAt: createdAt,
                                latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        panoramas.insert(panorama, at: 0)

        if coordinate != nil {
            var metas = loadMetadata()
            metas[id.uuidString] = PanoMeta(latitude: coordinate?.latitude, longitude: coordinate?.longitude)
            saveMetadata(metas)
        }

        return panorama
    }

    func delete(_ panorama: Panorama) {
        try? FileManager.default.removeItem(at: panorama.url)
        panoramas.removeAll { $0.id == panorama.id }

        var metas = loadMetadata()
        metas[panorama.id.uuidString] = nil
        saveMetadata(metas)
    }

    // MARK: - Metadata

    private func loadMetadata() -> [String: PanoMeta] {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([String: PanoMeta].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMetadata(_ metas: [String: PanoMeta]) {
        guard let data = try? JSONEncoder().encode(metas) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func creationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate ?? .distantPast
    }
}
