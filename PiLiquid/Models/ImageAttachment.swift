import AppKit
import Foundation

/// An image the user has attached to a prompt. Holds the base64 payload sent to
/// pi (as an RPC `ImageContent` block) plus a decoded `NSImage` for display.
struct ImageAttachment: Identifiable, Equatable {
    let id: String
    let mimeType: String
    /// Raw base64 of the (possibly re-encoded) image bytes — no `data:` prefix.
    let base64: String
    let image: NSImage

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool { lhs.id == rhs.id }

    /// The RPC `ImageContent` block pi expects: `{type:"image", data, mimeType}`.
    var rpcValue: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(base64),
            "mimeType": .string(mimeType),
        ])
    }

    /// Build from raw file/clipboard/drop bytes. Returns `nil` if the bytes
    /// aren't a decodable image. Formats pi accepts (png/jpeg/gif/webp) pass
    /// through untouched; anything else is re-encoded to PNG so the agent always
    /// receives a known type.
    init?(data rawData: Data) {
        let (bytes, mime) = ImageAttachment.normalize(rawData)
        guard let img = NSImage(data: bytes) else { return nil }
        self.id = UUID().uuidString
        self.image = img
        self.base64 = bytes.base64EncodedString()
        self.mimeType = mime
    }

    /// Build directly from a pi message's stored ImageContent (resume path).
    init?(base64: String, mimeType: String) {
        guard let data = Data(base64Encoded: base64), let img = NSImage(data: data) else { return nil }
        self.id = UUID().uuidString
        self.base64 = base64
        self.mimeType = mimeType
        self.image = img
    }

    private static func normalize(_ data: Data) -> (Data, String) {
        if let mime = sniffMime(data) { return (data, mime) }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        return (data, "image/png")
    }

    /// Detect the image type from magic bytes; `nil` for anything unrecognized.
    private static func sniffMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return nil }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }
}

extension ImageAttachment {
    /// Pull every image off the general pasteboard (⌘V), preserving order.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [ImageAttachment] {
        var out: [ImageAttachment] = []
        // File URLs first (Finder copy), then raw image data (screenshots, etc.).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where url.isFileURL {
                if let data = try? Data(contentsOf: url), let att = ImageAttachment(data: data) {
                    out.append(att)
                }
            }
        }
        if out.isEmpty,
           let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for img in imgs {
                if let tiff = img.tiffRepresentation, let att = ImageAttachment(data: tiff) {
                    out.append(att)
                }
            }
        }
        return out
    }

    /// True if the pasteboard currently carries an image we could attach.
    static func pasteboardHasImage(_ pb: NSPasteboard = .general) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
                .contains(where: { $0.isFileURL && NSImage(contentsOf: $0) != nil }) == true
    }
}
