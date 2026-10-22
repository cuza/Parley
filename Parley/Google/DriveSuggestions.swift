import Foundation

/// Drive files for the @ list's Files section, as Google Chat's web asks Task Assist: recent files for "@" alone
/// (mode 2), matches for a query (mode 4). The reply's field 14 holds [id, title, MIME type] triples.
struct DriveSuggestions: GoogleRequest {
    let query: String
    var host: GoogleHost { .taskAssist }
    var path: String { "/v2/taskassist:compose" }
    /// As web sends them; 15, 16, 28 and 34 are constants whose meaning isn't known.
    var fields: [Any?] {
        var fields = [Any?](repeating: nil, count: 34)
        fields[0] = query
        fields[2] = query.isEmpty ? 2 : 4
        fields[14] = 5; fields[15] = 12
        fields[27] = [10]
        fields[33] = [0, 1, [1]]
        return fields
    }
    var body: (data: Data, contentType: String) { get throws { try Self.jspb(fields) } }
    func reply(_ data: Data) throws -> [DriveFile] {
        let value = try JSPB.parse(data)
        var files: [DriveFile] = []
        // Field 14 nests the triples a few arrays deep: read any [id, title, type] list under it.
        func collect(_ node: Any?) {
            guard let array = node as? [Any] else { return }
            if array.count >= 3, let id = array[0] as? String, let title = array[1] as? String, let type = array[2] as? String,
               !id.isEmpty, type.contains("/") {
                files.append(DriveFile(id: id, title: title, mimeType: type))
                return
            }
            array.forEach(collect)
        }
        collect(JSPB.field(value, 14))
        return files
    }
}
