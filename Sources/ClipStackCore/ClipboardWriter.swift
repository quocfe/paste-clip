import AppKit

public enum ClipboardWriteError: LocalizedError {
    case missingAsset, missingFiles, failed
    public var errorDescription: String? {
        switch self {
        case .missingAsset: return "The saved image is no longer available."
        case .missingFiles: return "One or more original files have moved or been deleted."
        case .failed: return "Could not write to the clipboard. Please try again."
        }
    }
}

@MainActor
public enum ClipboardWriter {
    public static func write(_ clip: ClipboardItem, storage: StorageService, to board: NSPasteboard = .general) throws {
        var objects: [NSPasteboardWriting] = []
        if clip.type == .file {
            guard !clip.files.isEmpty, clip.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw ClipboardWriteError.missingFiles }
            for url in clip.files {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString("1", forType: ClipboardParser.ownMarker)
                objects.append(item)
            }
        } else {
            let item = NSPasteboardItem()
            item.setString("1", forType: ClipboardParser.ownMarker)
            if clip.type == .image {
                guard let name = clip.assetPath, let url = storage.assetURL(name), let data = try? Data(contentsOf: url) else { throw ClipboardWriteError.missingAsset }
                item.setData(data, forType: .png)
            } else {
                item.setString(clip.plainText, forType: .string)
                if let html = clip.html { item.setData(html, forType: .html) }
                if let rtf = clip.rtf { item.setData(rtf, forType: .rtf) }
                if let url = clip.url { item.setString(url, forType: .URL) }
            }
            objects.append(item)
        }
        board.clearContents()
        guard board.writeObjects(objects) else { throw ClipboardWriteError.failed }
    }
}
