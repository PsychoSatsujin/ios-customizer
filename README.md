# Customize

Personal iOS customization app: wallpapers, live wallpapers and custom icons
from your own images and videos. Built without a Mac.

## How it builds

1. Push to `main` (or run the workflow manually from the Actions tab).
2. GitHub Actions generates the Xcode project from `project.yml` with XcodeGen.
   Two jobs run in parallel on macOS runners:
   - **Unit tests (simulator)** builds the app and runs `Tests/` on the newest
     iPhone simulator.
   - **Build IPA** builds an unsigned `Customize.ipa`.
3. Download the `Customize-ipa` artifact from the workflow run and unzip it.
4. On Windows, open Sideloadly, plug in the iPhone, drop in `Customize.ipa`,
   sign in with your Apple ID and install.
5. First install only: on the iPhone, trust the developer under
   Settings > General > VPN & Device Management, and turn on Developer Mode
   under Settings > Privacy & Security if prompted.

Free Apple ID signing expires after 7 days; re-install with Sideloadly to
renew. Wallpapers and icons you already set keep working after it expires,
because they live in Photos and in a configuration profile, not in the app.

## Layout

- `project.yml` – project definition (no `.xcodeproj` is committed)
- `Sources/` – SwiftUI app code
  - `WallpaperView.swift` – Wallpaper tab
  - `Live/` – Live tab: `LivePhotoMaker` (video → Live Photo pair),
    preview, save to Photos
  - `Icons/` – Icons tab: icon store, app catalog, Web Clip profile builder,
    loopback HTTP server that hands the profile to Safari
- `Tests/` – XCTest unit tests (run in CI on the simulator)
- `.github/workflows/build.yml` – cloud build and tests

## Using it

### Wallpaper

Pick an image and save it to Photos. Set it from Photos
(Share > Use as Wallpaper) or with a Shortcut.

### Live wallpaper

1. In the Live tab, choose a video, pick the part to use (1–3 s; longer
   parts are sped up into the 1-second Live Photo) and the key photo
   (the middle is the setting known to work), then tap **Create Live Photo**.
   Press and hold the preview to play it, then **Save to Photos**.
2. Turn off Low Power Mode (and ideally Reduce Motion): both stop
   Lock Screen motion.
3. Photos > the new Live Photo > Share > **Use as Wallpaper**, or
   Settings > Wallpaper > Add New Wallpaper > Live Photo / Photos.
4. Make sure the **Live** button at the bottom of the preview is on, tap
   Add, then Set as Wallpaper Pair (or Lock Screen only).
5. Lock and wake the phone: the clip plays once on the Lock Screen.

If iOS says "Motion not available", try a different, steadier part of the
video. Why it is built this way: since iOS 17, Lock Screen motion needs
undocumented metadata (a `live-photo-info` timed-metadata track) that
regular app-made Live Photos lack. The app copies a neutral template of
those tracks into a 1080×1920, 60 fps, 1 s H.264 movie, the only format
reported to animate. The template bytes come from the open-source
[Video2LivePhoto](https://github.com/TouSC/Video2LivePhoto) project.
Turn off **Lock Screen motion data** in the Live tab to make a plain
Live Photo without that metadata.

### Icons

1. In the Icons tab, tap **+**, pick an image, choose the app it should open
   from the list (or type any custom URL scheme or https link), set a label.
   Use **Test link** to check the app opens.
2. Tap **Install on Home Screen**. A Safari sheet opens inside the app; tap
   **Allow** to download the profile, then **Close**. If that does not offer
   the download, use **Open in Safari app instead**, or **Save profile file**
   then open the saved `.mobileconfig` from the Files app.
3. Within about 8 minutes open Settings > **Profile Downloaded** (or
   General > VPN & Device Management), tap **Install**, enter your passcode,
   accept the "Not Verified" warning (expected: you made the profile) and
   tap Install again.
4. The icons appear on the Home Screen; each opens its app. Move the
   original apps to the App Library to hide them.

To change icons, edit them and install again: the new profile replaces the
old one. To remove all of them, Settings > General > VPN & Device Management
> Customize Icons > Remove Profile. With Stolen Device Protection on,
installing a profile may need you to be at a familiar location.
Web Clip icons show no notification badges and may not follow dark or
tinted icon styles.

## Status

- Wallpaper tab: pick an image, save to Photos
- Live tab: video → Live Photo with Lock Screen motion metadata, preview,
  save to Photos
- Icons tab: custom icons for any app with a URL scheme, installed as a
  configuration profile

Still to confirm on a real iPhone (the simulator can't show either):
Lock Screen motion of the generated Live Photos, and whether tapping a
Web Clip opens the app directly or flashes Safari first.
