import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            WallpaperView()
                .tabItem { Label("Wallpaper", systemImage: "photo") }

            LiveWallpaperView()
                .tabItem { Label("Live", systemImage: "livephoto") }

            IconsView()
                .tabItem { Label("Icons", systemImage: "square.grid.2x2") }
        }
    }
}
