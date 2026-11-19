# Customize

Personal iOS customization app: wallpapers, live wallpapers and custom icons
from your own images and videos. Built without a Mac.

## How it builds

1. Push to `main` (or run the workflow manually from the Actions tab).
2. GitHub Actions generates the Xcode project from `project.yml` with XcodeGen
   and builds an unsigned `Customize.ipa` on a macOS runner.
3. Download the `Customize-ipa` artifact from the workflow run and unzip it.
4. On Windows, open Sideloadly, plug in the iPhone, drop in `Customize.ipa`,
   sign in with your Apple ID and install.
5. First install only: on the iPhone, trust the developer under
   Settings > General > VPN & Device Management, and turn on Developer Mode
   under Settings > Privacy & Security if prompted.

## Layout

- `project.yml` – project definition (no `.xcodeproj` is committed)
- `Sources/` – SwiftUI app code
- `.github/workflows/build.yml` – cloud build

## Status

- Wallpaper tab: pick an image, save to Photos (working slice)
- Live tab, Icons tab: placeholders
