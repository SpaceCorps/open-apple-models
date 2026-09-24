import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Builds a prompt from arguments, piped standard input and image files.
enum PromptInput {
    /// Whether standard input is a pipe or a regular file (not a terminal,
    /// socket or device), i.e. something that was deliberately piped in.
    static var stdinIsPiped: Bool {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFIFO || type == S_IFREG
    }

    /// Reads all of standard input as text.
    static func readStandardInput() -> String {
        var text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The prompt text: the arguments, followed by piped standard input.
    /// Standard input alone is used when there are no arguments.
    ///
    /// - Parameter readsStandardInput: Whether piped input may be read.
    /// - Returns: `nil` when there is no prompt at all.
    static func text(arguments: [String], readsStandardInput: Bool) -> String? {
        let joined = arguments.joined(separator: " ")
        var parts: [String] = []
        if !joined.isEmpty { parts.append(joined) }
        if readsStandardInput, joined.isEmpty ? !Console.stdinIsTerminal : stdinIsPiped {
            let piped = readStandardInput()
            if !piped.isEmpty { parts.append(piped) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A prompt with text and image attachments.
    static func prompt(text: String, images: [String]) throws(CLIError) -> Prompt {
        guard !images.isEmpty else { return Prompt(text) }
        var pieces: [Prompt] = []
        for path in images {
            let image = try loadImage(path)
            pieces.append(Prompt(Attachment(image.image, orientation: image.orientation)))
        }
        if !text.isEmpty { pieces.append(Prompt(text)) }
        return Prompt(pieces)
    }

    /// Decodes an image file (PNG, JPEG, HEIC, GIF, WebP, …).
    static func loadImage(_ path: String) throws(CLIError) -> (image: CGImage, orientation: CGImagePropertyOrientation?) {
        let url = URL(fileURLWithPath: InputFiles.absolute(path))
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw .invalidInput("Cannot read image '\(path)'.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .invalidInput("'\(path)' is not a supported image (PNG, JPEG, HEIC, GIF, WebP, …).")
        }
        var orientation: CGImagePropertyOrientation?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32 {
            orientation = CGImagePropertyOrientation(rawValue: raw)
        }
        return (image, orientation)
    }
}
