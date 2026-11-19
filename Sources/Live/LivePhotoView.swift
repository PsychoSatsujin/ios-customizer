import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Shows a `PHLivePhoto`; press and hold to play it, like in Photos.
struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto?

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        guard uiView.livePhoto !== livePhoto else { return }
        uiView.livePhoto = livePhoto
        if livePhoto != nil {
            // A short "hint" play shows the photo is live.
            uiView.startPlayback(with: .hint)
        }
    }
}

/// Builds a `PHLivePhoto` from a still + paired movie on disk (no Photos permission needed).
enum LivePhotoLoader {
    /// How long to wait for the full-quality result. When pairing quietly fails, Photos may only
    /// ever deliver the degraded placeholder.
    static let defaultTimeout: Double = 20

    /// Resumes once: with the first full-quality result, or with an error (failure, cancellation or
    /// timeout). Degraded (placeholder) results are skipped, because the handler can be called more
    /// than once.
    static func load(
        photoURL: URL,
        videoURL: URL,
        targetSize: CGSize = .zero,
        timeout: Double = LivePhotoLoader.defaultTimeout
    ) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHLivePhoto, Error>) in
            let resumeOnce = LivePhotoOnceFlag()
            _ = PHLivePhoto.request(
                withResourceFileURLs: [photoURL, videoURL],
                placeholderImage: nil,
                targetSize: targetSize,
                contentMode: .aspectFit
            ) { livePhoto, info in
                if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                    if resumeOnce.claim() {
                        continuation.resume(throwing: LivePhotoError.previewFailed(error.localizedDescription))
                    }
                    return
                }
                if (info[PHLivePhotoInfoCancelledKey] as? Bool) == true {
                    if resumeOnce.claim() {
                        continuation.resume(throwing: LivePhotoError.previewFailed("The request was cancelled."))
                    }
                    return
                }
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true {
                    return
                }
                guard resumeOnce.claim() else { return }
                if let livePhoto {
                    continuation.resume(returning: livePhoto)
                } else {
                    continuation.resume(
                        throwing: LivePhotoError.previewFailed("Photos could not pair the photo and the video.")
                    )
                }
            }
            // Any later handler call is ignored by `resumeOnce`.
            let seconds: Double = timeout.isFinite && timeout > 0 ? timeout : LivePhotoLoader.defaultTimeout
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard resumeOnce.claim() else { return }
                continuation.resume(
                    throwing: LivePhotoError.previewFailed("Photos did not finish building it in time.")
                )
            }
        }
    }
}
