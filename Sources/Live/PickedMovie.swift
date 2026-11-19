import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A video picked with `PhotosPicker(matching: .videos)`.
///
/// The file Photos hands over is deleted as soon as the import closure returns, so it is copied
/// to a unique temporary location first.
struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = try PickedMovie.makeUniqueCopy(of: received.file)
            return PickedMovie(url: copy)
        }
    }

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PickedMovies", isDirectory: true)
    }

    /// Copies `source` to `<tmp>/PickedMovies/<UUID>.<ext>` and returns the new URL.
    static func makeUniqueCopy(of source: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
}
