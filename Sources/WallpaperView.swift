import SwiftUI
import PhotosUI
import UIKit

/// First working slice: pick an image, preview it, save it to Photos.
/// From Photos it can be set as wallpaper (manually or via a Shortcut),
/// and it keeps working even when this app's signing has expired.
struct WallpaperView: View {
    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var status: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxHeight: 420)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 420)
                        .overlay(Text("No image selected").foregroundStyle(.secondary))
                }

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Choose image", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    save()
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(image == nil)

                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Wallpaper")
            .onChange(of: pickedItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let loaded = UIImage(data: data) {
                        image = loaded
                        status = ""
                    } else {
                        status = "Could not load that image."
                    }
                }
            }
        }
    }

    private func save() {
        guard let image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        status = "Saved. Set it from Photos or with a Shortcut."
    }
}
