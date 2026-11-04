import Foundation

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// A file's MIME type from its extension: the system's type database on Apple platforms, a table of the types people
/// send in chat elsewhere.
public enum FileTypes {
    public static func mimeType(forExtension ext: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
            UTType(filenameExtension: ext)?.preferredMIMEType
        #else
            table[ext.lowercased()]
        #endif
    }

    #if !canImport(UniformTypeIdentifiers)
        static let table: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
            "heic": "image/heic", "svg": "image/svg+xml", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
            "pdf": "application/pdf", "txt": "text/plain", "csv": "text/csv", "html": "text/html",
            "json": "application/json",
            "zip": "application/zip", "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
            "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ]
    #endif
}
