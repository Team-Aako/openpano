//
//  UIImage+Pano.swift
//  openpano
//
//  Image scaling helpers used by capture and the gallery.
//

import UIKit
import ImageIO
import CoreLocation
import UniformTypeIdentifiers

extension UIImage {
    /// Returns a copy scaled so its longest side equals `maxLength`, at 1x scale.
    func resizeToFit(maxLength: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return self }
        let scale = maxLength / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // pixel-accurate, no device scale inflation
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Encodes a UIImage to JPEG data, embedding capture date (EXIF/TIFF) and, if
/// available, GPS coordinates so the location travels with the file.
func jpegDataWithMetadata(
    _ image: UIImage,
    coordinate: CLLocationCoordinate2D?,
    date: Date,
    quality: CGFloat = 0.9
) -> Data? {
    guard let cgImage = image.cgImage else {
        return image.jpegData(compressionQuality: quality)
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        return image.jpegData(compressionQuality: quality)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let dateString = formatter.string(from: date)

    var properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: dateString,
            kCGImagePropertyExifDateTimeDigitized: dateString
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: dateString
        ]
    ]

    if let coordinate {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp: dateString
        ]
    }

    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        return image.jpegData(compressionQuality: quality)
    }
    return data as Data
}

/// Decodes a downsampled thumbnail from a file without fully decoding the
/// source image — keeps the gallery grid memory-light for 4096×2048 panoramas.
func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
        return nil
    }
    let scale = UIScreen.main.scale
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * scale
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}
