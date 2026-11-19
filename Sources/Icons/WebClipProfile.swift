import Foundation
import CryptoKit

/// Why a profile could not be built. Describes the first bad icon.
enum WebClipProfileError: LocalizedError, Equatable {
    case noIcons
    /// `position` is 1-based, matching the order in the list.
    case missingLabel(position: Int)
    case duplicateIcon(label: String)
    case invalidLink(label: String, link: String)
    case missingImage(label: String)
    case invalidImage(label: String)

    var errorDescription: String? {
        switch self {
        case .noIcons:
            return "Add at least one icon first."
        case .missingLabel(let position):
            return "Icon \(position) has no label. Give it a name."
        case .duplicateIcon(let label):
            return "\"\(label)\" is in the list twice."
        case .invalidLink(let label, let link):
            let shown = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.isEmpty {
                return "\"\(label)\" has no link. Pick an app or type a link like instagram://."
            }
            return "\"\(label)\" has an invalid link (\(shown)). Use a link like instagram:// or https://example.com."
        case .missingImage(let label):
            return "\"\(label)\" has no image. Open it and choose one."
        case .invalidImage(let label):
            return "\"\(label)\" has an image that can't be used. Open it and choose the image again."
        }
    }
}

/// Builds an unsigned configuration profile (.mobileconfig) with one
/// com.apple.webClip.managed payload per icon. Installing it from Settings
/// adds the icons to the Home Screen; tapping one opens its link.
enum WebClipProfile {
    /// Stable top-level identifier: installing again replaces the installed profile.
    static let profileIdentifier = "com.personal.customize.icons"
    static let displayName = "Custom Icons"
    static let organization = "Customize"
    static let profileDescription = "Adds the custom Home Screen icons you made in Customize. Remove this profile to remove them all."
    static let fileName = "Customize-Icons.mobileconfig"
    static let contentType = "application/x-apple-aspen-config"
    static let webClipPayloadType = "com.apple.webClip.managed"
    /// Apple's limit for web clip icons: square, at most 400 x 400 pixels.
    static let maxIconPixels = 400

    struct Entry: Equatable {
        var item: IconItem
        var iconPNG: Data?

        init(item: IconItem, iconPNG: Data?) {
            self.item = item
            self.iconPNG = iconPNG
        }
    }

    /// Per-icon PayloadIdentifier. Stable for the life of the icon.
    static func clipIdentifier(for id: UUID) -> String {
        "\(profileIdentifier).clip.\(id.uuidString)"
    }

    /// Returns the URL for a launch link, or nil if it can't be used.
    /// Accepts any scheme (instagram://, sms:, App-prefs:) and http(s) links with a host.
    /// Spaces inside the link are sent as %20, because shortcut names usually
    /// contain them (shortcuts://run-shortcut?name=Open Camera). Tabs and line
    /// breaks make the link invalid.
    static func launchURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.replacingOccurrences(of: " ", with: "%20")
        guard !encoded.contains(where: { $0.isWhitespace }) else { return nil }
        guard let url = URL(string: encoded), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        let lowered = scheme.lowercased()
        if lowered == "http" || lowered == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
        }
        return url
    }

    /// Checks every entry in order and throws for the first bad one.
    static func validate(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { throw WebClipProfileError.noIcons }
        var seen = Set<UUID>()
        for (offset, entry) in entries.enumerated() {
            let label = entry.item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else {
                throw WebClipProfileError.missingLabel(position: offset + 1)
            }
            guard seen.insert(entry.item.id).inserted else {
                throw WebClipProfileError.duplicateIcon(label: label)
            }
            guard launchURL(from: entry.item.launchURL) != nil else {
                throw WebClipProfileError.invalidLink(label: label, link: entry.item.launchURL)
            }
            guard let png = entry.iconPNG, !png.isEmpty else {
                throw WebClipProfileError.missingImage(label: label)
            }
            guard let size = IconRenderer.pngPixelSize(png),
                  size.width > 0,
                  size.width == size.height,
                  size.width <= maxIconPixels else {
                throw WebClipProfileError.invalidImage(label: label)
            }
        }
    }

    /// The profile as a property-list dictionary (validated).
    static func propertyList(entries: [Entry], profileUUID: UUID) throws -> [String: Any] {
        try validate(entries)

        var clips: [[String: Any]] = []
        for entry in entries {
            let item = entry.item
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = launchURL(from: item.launchURL) else {
                throw WebClipProfileError.invalidLink(label: label, link: item.launchURL)
            }
            guard let png = entry.iconPNG else {
                throw WebClipProfileError.missingImage(label: label)
            }
            let link = url.absoluteString
            let clip: [String: Any] = [
                "PayloadType": webClipPayloadType,
                "PayloadVersion": 1,
                "PayloadIdentifier": clipIdentifier(for: item.id),
                "PayloadUUID": clipUUID(for: item.id, label: label, launchURL: link, iconPNG: png),
                "PayloadDisplayName": label,
                "PayloadDescription": "Opens \(link)",
                "Label": label,
                "URL": link,
                "Icon": png,
                "IsRemovable": true,
                "FullScreen": false,
                "Precomposed": true,
            ]
            clips.append(clip)
        }

        let profile: [String: Any] = [
            "PayloadContent": clips,
            "PayloadDisplayName": displayName,
            "PayloadDescription": profileDescription,
            "PayloadOrganization": organization,
            "PayloadIdentifier": profileIdentifier,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID.uuidString,
            "PayloadVersion": 1,
            "PayloadRemovalDisallowed": false,
            "TargetDeviceType": 1,
        ]
        return profile
    }

    /// The profile as XML property-list data, ready to serve or save as a .mobileconfig file.
    static func build(entries: [Entry], profileUUID: UUID) throws -> Data {
        let plist = try propertyList(entries: entries, profileUUID: profileUUID)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Per-icon PayloadUUID derived from the icon's id plus its label, link and
    /// image. It is the same on every build while the icon is unchanged and
    /// changes when the icon is edited, so iOS refreshes the cached artwork.
    static func clipUUID(for id: UUID, label: String, launchURL: String, iconPNG: Data) -> String {
        var input = Data(id.uuidString.utf8)
        input.append(UInt8(0))
        input.append(contentsOf: Array(label.utf8))
        input.append(UInt8(0))
        input.append(contentsOf: Array(launchURL.utf8))
        input.append(UInt8(0))
        input.append(iconPNG)

        let digest: [UInt8] = Array(SHA256.hash(data: input))
        var b: [UInt8] = Array(digest[0..<16])
        b[6] = (b[6] & 0x0F) | 0x50  // name-based UUID (version 5 layout)
        b[8] = (b[8] & 0x3F) | 0x80  // RFC 4122 variant
        let uuid = UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
        return uuid.uuidString
    }
}
