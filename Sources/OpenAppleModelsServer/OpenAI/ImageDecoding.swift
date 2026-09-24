import CoreGraphics
import Foundation
import ImageIO

/// Decodes `image_url` content parts. Only inline `data:` URLs are accepted:
/// the server never fetches remote URLs on a client's behalf.
enum ImageDecoding {
    struct Decoded {
        var image: CGImage
        var orientation: CGImagePropertyOrientation?
    }

    /// Decodes a `data:[<mediatype>][;base64],<data>` URL with ImageIO.
    static func decode(dataURL url: String, param: String) throws(OpenAIError) -> Decoded {
        let lowered = url.prefix(16).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("file:") {
            throw .invalidRequest(
                "Remote image URLs are not supported. Send the image inline as a base64 data URL (data:image/png;base64,...).",
                param: param, code: "unsupported_image_url")
        }
        guard lowered.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else {
            throw .invalidRequest("Invalid image URL: expected a data: URL.", param: param, code: "invalid_image_url")
        }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = url[url.index(after: comma)...]
        let data: Data?
        if header.split(separator: ";").contains("base64") {
            data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
        } else {
            data = String(payload).removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else {
            throw .invalidRequest("The image data URL could not be decoded.", param: param, code: "invalid_image_url")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .invalidRequest("The image could not be decoded. Supported formats include PNG, JPEG, HEIC, GIF and WebP.",
                                  param: param, code: "invalid_image")
        }
        var orientation: CGImagePropertyOrientation?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32 {
            orientation = CGImagePropertyOrientation(rawValue: raw)
        }
        return Decoded(image: image, orientation: orientation)
    }
}
