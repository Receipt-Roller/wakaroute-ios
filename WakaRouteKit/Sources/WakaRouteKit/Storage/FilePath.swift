import Foundation

extension URL {
    /// The file system path, with no percent-encoding.
    ///
    /// `URL.path()` encodes by default, so a URL under **Application Support**
    /// comes back as `Application%20Support` and every `FileManager` call
    /// against it fails silently — `fileExists` simply answers false. Nothing
    /// throws, so a store built that way appears to work: it writes correctly
    /// and reads back nothing, quietly starting empty on every launch and
    /// overwriting whatever was there.
    ///
    /// Every path handed to `FileManager` goes through here rather than
    /// `path()`, so this cannot be reintroduced one store at a time.
    var filePath: String {
        path(percentEncoded: false)
    }
}
