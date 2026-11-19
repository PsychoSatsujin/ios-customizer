import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            WallpaperView()
                .tabItem { Label("Wallpaper", systemImage: "photo") }

            PlaceholderView(
                title: "Live Wallpaper",
                detail: "Turn a video into a Live Photo you can set on the Lock Screen."
            )
            .tabItem { Label("Live", systemImage: "livephoto") }

            PlaceholderView(
                title: "Icons",
                detail: "Build custom Home Screen icons that launch your apps."
            )
            .tabItem { Label("Icons", systemImage: "square.grid.2x2") }
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Coming next")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle(title)
        }
    }
}
