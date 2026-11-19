import XCTest
import UIKit
@testable import Customize

final class WebClipProfileTests: XCTestCase {
    private let profileUUID = UUID(uuidString: "6A1D2C3B-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let instagramID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let notesID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

    // MARK: - Helpers

    private func solidImage(_ color: UIColor, width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func iconPNG(_ color: UIColor) -> Data {
        IconRenderer.renderPNG(from: solidImage(color, width: 300, height: 200))
    }

    private func sampleEntries(instagramColor: UIColor = .systemPink) -> [WebClipProfile.Entry] {
        [
            WebClipProfile.Entry(
                item: IconItem(id: instagramID, label: "Instagram", launchURL: "instagram://"),
                iconPNG: iconPNG(instagramColor)
            ),
            WebClipProfile.Entry(
                item: IconItem(id: notesID, label: "  Notes ", launchURL: "mobilenotes://"),
                iconPNG: iconPNG(.systemYellow)
            ),
        ]
    }

    private func parse(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        XCTAssertEqual(format, .xml, "The profile should be an XML property list", file: file, line: line)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    private func clips(_ plist: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]], "PayloadContent should be an array of dictionaries", file: file, line: line)
    }

    private func assertString(_ dict: [String: Any], _ key: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let value = dict[key] else {
            XCTFail("\(key) is missing", file: file, line: line)
            return
        }
        XCTAssertTrue(value is String, "\(key) should be a <string>", file: file, line: line)
        XCTAssertEqual(value as? String, expected, key, file: file, line: line)
    }

    private func assertInteger(_ dict: [String: Any], _ key: String, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let value = dict[key] else {
            XCTFail("\(key) is missing", file: file, line: line)
            return
        }
        XCTAssertEqual(CFGetTypeID(value as AnyObject), CFNumberGetTypeID(), "\(key) should be an <integer>", file: file, line: line)
        XCTAssertEqual(value as? Int, expected, key, file: file, line: line)
    }

    private func assertBool(_ dict: [String: Any], _ key: String, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let value = dict[key] else {
            XCTFail("\(key) is missing", file: file, line: line)
            return
        }
        XCTAssertEqual(CFGetTypeID(value as AnyObject), CFBooleanGetTypeID(), "\(key) should be <true/> or <false/>", file: file, line: line)
        XCTAssertEqual(value as? Bool, expected, key, file: file, line: line)
    }

    private func assertValidationError(
        _ entries: [WebClipProfile.Entry],
        _ expected: WebClipProfileError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try WebClipProfile.build(entries: entries, profileUUID: profileUUID), file: file, line: line) { error in
            XCTAssertEqual(error as? WebClipProfileError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    // MARK: - Top level

    func testTopLevelKeysTypesAndValues() throws {
        let data = try WebClipProfile.build(entries: sampleEntries(), profileUUID: profileUUID)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xml"))
        XCTAssertTrue(text.contains("<!DOCTYPE plist"))

        let plist = try parse(data)
        XCTAssertEqual(Set(plist.keys), [
            "PayloadContent", "PayloadDisplayName", "PayloadDescription", "PayloadOrganization",
            "PayloadIdentifier", "PayloadType", "PayloadUUID", "PayloadVersion",
            "PayloadRemovalDisallowed", "TargetDeviceType",
        ])
        assertString(plist, "PayloadType", "Configuration")
        assertInteger(plist, "PayloadVersion", 1)
        assertString(plist, "PayloadIdentifier", "com.personal.customize.icons")
        assertString(plist, "PayloadUUID", profileUUID.uuidString)
        assertString(plist, "PayloadDisplayName", "Custom Icons")
        assertString(plist, "PayloadOrganization", "Customize")
        assertString(plist, "PayloadDescription", WebClipProfile.profileDescription)
        assertBool(plist, "PayloadRemovalDisallowed", false)
        assertInteger(plist, "TargetDeviceType", 1)
        XCTAssertNil(plist["TargetApplicationBundleIdentifier"])
    }

    // MARK: - Web clips

    func testWebClipPayloadKeysTypesAndValues() throws {
        let entries = sampleEntries()
        let plist = try parse(try WebClipProfile.build(entries: entries, profileUUID: profileUUID))
        let content = try clips(plist)
        XCTAssertEqual(content.count, 2)

        let expectedKeys: Set<String> = [
            "PayloadType", "PayloadVersion", "PayloadIdentifier", "PayloadUUID",
            "PayloadDisplayName", "PayloadDescription", "Label", "URL", "Icon",
            "IsRemovable", "FullScreen", "Precomposed",
        ]

        for (index, clip) in content.enumerated() {
            XCTAssertEqual(Set(clip.keys), expectedKeys, "clip \(index)")
            assertString(clip, "PayloadType", "com.apple.webClip.managed")
            assertInteger(clip, "PayloadVersion", 1)
            assertBool(clip, "IsRemovable", true)
            assertBool(clip, "FullScreen", false)
            assertBool(clip, "Precomposed", true)

            let label = try XCTUnwrap(clip["Label"] as? String)
            XCTAssertFalse(label.isEmpty)
            XCTAssertEqual(clip["PayloadDisplayName"] as? String, label)

            let link = try XCTUnwrap(clip["URL"] as? String)
            let url = try XCTUnwrap(URL(string: link))
            XCTAssertFalse((url.scheme ?? "").isEmpty)
            XCTAssertEqual(clip["PayloadDescription"] as? String, "Opens \(link)")

            let uuidString = try XCTUnwrap(clip["PayloadUUID"] as? String)
            XCTAssertNotNil(UUID(uuidString: uuidString), "PayloadUUID should be a UUID string")

            let icon = try XCTUnwrap(clip["Icon"] as? Data, "Icon should be <data>")
            XCTAssertEqual(icon, entries[index].iconPNG)
            XCTAssertEqual(Array(icon.prefix(8)), IconRenderer.pngSignature)
            let image = try XCTUnwrap(UIImage(data: icon))
            XCTAssertEqual(image.cgImage?.width, IconRenderer.pixelSize)
            XCTAssertEqual(image.cgImage?.height, IconRenderer.pixelSize)
        }

        assertString(content[0], "Label", "Instagram")
        assertString(content[0], "URL", "instagram://")
        assertString(content[0], "PayloadIdentifier", "com.personal.customize.icons.clip.\(instagramID.uuidString)")
        assertString(content[1], "Label", "Notes")
        assertString(content[1], "URL", "mobilenotes://")
        assertString(content[1], "PayloadIdentifier", "com.personal.customize.icons.clip.\(notesID.uuidString)")
    }

    func testIdentifiersAndUUIDsAreUnique() throws {
        let plist = try parse(try WebClipProfile.build(entries: sampleEntries(), profileUUID: profileUUID))
        let content = try clips(plist)
        let identifiers = content.compactMap { $0["PayloadIdentifier"] as? String } + [plist["PayloadIdentifier"] as? String ?? ""]
        let uuids = content.compactMap { $0["PayloadUUID"] as? String } + [plist["PayloadUUID"] as? String ?? ""]
        XCTAssertEqual(identifiers.count, 3)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(uuids.count, 3)
        XCTAssertEqual(Set(uuids).count, uuids.count)
    }

    func testIdentifiersAreStableAcrossBuilds() throws {
        let entries = sampleEntries()
        let first = try parse(try WebClipProfile.build(entries: entries, profileUUID: profileUUID))
        let second = try parse(try WebClipProfile.build(entries: entries, profileUUID: profileUUID))

        XCTAssertEqual(first["PayloadIdentifier"] as? String, second["PayloadIdentifier"] as? String)
        XCTAssertEqual(first["PayloadUUID"] as? String, second["PayloadUUID"] as? String)
        XCTAssertEqual(
            try clips(first).map { $0["PayloadIdentifier"] as? String },
            try clips(second).map { $0["PayloadIdentifier"] as? String }
        )
        XCTAssertEqual(
            try clips(first).map { $0["PayloadUUID"] as? String },
            try clips(second).map { $0["PayloadUUID"] as? String }
        )
    }

    func testTopLevelIdentifierDoesNotDependOnProfileUUID() throws {
        let otherUUID = UUID()
        let plist = try parse(try WebClipProfile.build(entries: sampleEntries(), profileUUID: otherUUID))
        assertString(plist, "PayloadIdentifier", WebClipProfile.profileIdentifier)
        assertString(plist, "PayloadUUID", otherUUID.uuidString)
    }

    func testEditedIconGetsNewPayloadUUIDButKeepsIdentifier() throws {
        let before = try clips(parse(try WebClipProfile.build(entries: sampleEntries(instagramColor: .systemPink), profileUUID: profileUUID)))
        let after = try clips(parse(try WebClipProfile.build(entries: sampleEntries(instagramColor: .systemGreen), profileUUID: profileUUID)))

        XCTAssertEqual(before[0]["PayloadIdentifier"] as? String, after[0]["PayloadIdentifier"] as? String)
        XCTAssertNotEqual(before[0]["PayloadUUID"] as? String, after[0]["PayloadUUID"] as? String)

        let a = WebClipProfile.clipUUID(for: instagramID, label: "Instagram", launchURL: "instagram://", iconPNG: Data([1, 2, 3]))
        let b = WebClipProfile.clipUUID(for: instagramID, label: "Instagram", launchURL: "instagram://", iconPNG: Data([1, 2, 3]))
        let otherLink = WebClipProfile.clipUUID(for: instagramID, label: "Instagram", launchURL: "instagram://camera", iconPNG: Data([1, 2, 3]))
        let otherItem = WebClipProfile.clipUUID(for: notesID, label: "Instagram", launchURL: "instagram://", iconPNG: Data([1, 2, 3]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, otherLink)
        XCTAssertNotEqual(a, otherItem)
        XCTAssertNotNil(UUID(uuidString: a))
    }

    // MARK: - Validation

    func testValidationRejectsEmptyList() {
        assertValidationError([], .noIcons)
    }

    func testValidationRejectsMissingLabel() {
        var entries = sampleEntries()
        entries[1].item.label = "   "
        assertValidationError(entries, .missingLabel(position: 2))
    }

    func testValidationRejectsBadLinks() {
        for bad in ["", "instagram", "http://", "https://", "not a link"] {
            var entries = sampleEntries()
            entries[0].item.launchURL = bad
            assertValidationError(entries, .invalidLink(label: "Instagram", link: bad))
        }
    }

    func testValidationRejectsMissingOrUnusableImage() {
        var missing = sampleEntries()
        missing[1].iconPNG = nil
        assertValidationError(missing, .missingImage(label: "Notes"))

        var notPNG = sampleEntries()
        notPNG[1].iconPNG = Data([0x01, 0x02, 0x03, 0x04])
        assertValidationError(notPNG, .invalidImage(label: "Notes"))

        var notSquare = sampleEntries()
        notSquare[1].iconPNG = solidImage(.red, width: 300, height: 200).pngData()
        assertValidationError(notSquare, .invalidImage(label: "Notes"))

        var tooBig = sampleEntries()
        tooBig[1].iconPNG = IconRenderer.renderPNG(from: solidImage(.red, width: 50, height: 50), pixelSize: 512)
        assertValidationError(tooBig, .invalidImage(label: "Notes"))
    }

    func testValidationRejectsDuplicateIcons() {
        let entries = sampleEntries()
        assertValidationError([entries[0], entries[0]], .duplicateIcon(label: "Instagram"))
    }

    func testValidationReportsFirstBadItem() {
        var entries = sampleEntries()
        entries[0].item.launchURL = "nope"
        entries[1].iconPNG = nil
        assertValidationError(entries, .invalidLink(label: "Instagram", link: "nope"))
    }

    func testErrorDescriptionNamesTheIcon() {
        var entries = sampleEntries()
        entries[1].iconPNG = nil
        XCTAssertThrowsError(try WebClipProfile.build(entries: entries, profileUUID: profileUUID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Notes"), error.localizedDescription)
        }
    }

    func testLaunchURLParsing() {
        for good in ["instagram://", "sms:", "slack://open", "App-prefs:", "https://example.com/page?x=1", "  spotify://  "] {
            XCTAssertNotNil(WebClipProfile.launchURL(from: good), good)
        }
        for bad in ["", "   ", "instagram", "http://", "https://", "not a link", "://nothing", "insta\tgram://", "instagram://\nmore"] {
            XCTAssertNil(WebClipProfile.launchURL(from: bad), bad)
        }
        XCTAssertEqual(WebClipProfile.launchURL(from: " spotify:// ")?.absoluteString, "spotify://")
    }

    func testSpacesInLinksAreSentAsPercent20() throws {
        let raw = "shortcuts://run-shortcut?name=Open Camera"
        let url = try XCTUnwrap(WebClipProfile.launchURL(from: raw))
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.absoluteString, "shortcuts://run-shortcut?name=Open%20Camera")

        var entries = sampleEntries()
        entries[1].item.launchURL = raw
        let content = try clips(parse(try WebClipProfile.build(entries: entries, profileUUID: profileUUID)))
        assertString(content[1], "URL", "shortcuts://run-shortcut?name=Open%20Camera")
        assertString(content[1], "PayloadDescription", "Opens shortcuts://run-shortcut?name=Open%20Camera")
    }

    // MARK: - Catalog

    func testCatalogEntriesHaveUsableLinks() {
        XCTAssertFalse(AppCatalog.apps.isEmpty)
        var names = Set<String>()
        for app in AppCatalog.apps {
            XCTAssertNotNil(WebClipProfile.launchURL(from: app.launchURL), "\(app.name): \(app.launchURL)")
            XCTAssertTrue(names.insert(app.name.lowercased()).inserted, "Duplicate catalog name \(app.name)")
            XCTAssertFalse(app.symbol.isEmpty, app.name)
        }
    }

    func testCatalogSearch() {
        XCTAssertEqual(AppCatalog.search("").count, AppCatalog.apps.count)
        XCTAssertTrue(AppCatalog.search("INSTA").contains { $0.name == "Instagram" })
        XCTAssertTrue(AppCatalog.search("twitter").contains { $0.name == "X" })
        XCTAssertTrue(AppCatalog.search("zzzz-no-such-app").isEmpty)
        XCTAssertEqual(AppCatalog.app(matching: " instagram:// ")?.name, "Instagram")
        XCTAssertNil(AppCatalog.app(matching: "unknown-scheme://"))
    }

    // MARK: - Renderer

    func testRendererMakesSquarePNGFromNonSquareImage() throws {
        let png = IconRenderer.renderPNG(from: solidImage(.red, width: 300, height: 120))
        XCTAssertTrue(IconRenderer.isPNG(png))
        let size = try XCTUnwrap(IconRenderer.pngPixelSize(png))
        XCTAssertEqual(size.width, IconRenderer.pixelSize)
        XCTAssertEqual(size.height, IconRenderer.pixelSize)
        XCTAssertLessThanOrEqual(IconRenderer.pixelSize, WebClipProfile.maxIconPixels)
        XCTAssertLessThan(png.count, 1_000_000)

        let image = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(image.cgImage?.width, IconRenderer.pixelSize)
        XCTAssertEqual(image.cgImage?.height, IconRenderer.pixelSize)
    }

    func testRendererHonorsCustomSize() throws {
        let png = IconRenderer.renderPNG(from: solidImage(.blue, width: 40, height: 90), background: .black, pixelSize: 180)
        let size = try XCTUnwrap(IconRenderer.pngPixelSize(png))
        XCTAssertEqual(size.width, 180)
        XCTAssertEqual(size.height, 180)
    }

    func testDownsamplingLimitsTheLongestSide() throws {
        let big = try XCTUnwrap(solidImage(.blue, width: 1600, height: 900).pngData())
        let image = try XCTUnwrap(IconRenderer.downsampledImage(from: big, maxPixelSize: 400))
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 400)
        XCTAssertGreaterThan(max(cgImage.width, cgImage.height), 300)
    }

    func testPNGSizeReaderRejectsNonPNGData() {
        XCTAssertNil(IconRenderer.pngPixelSize(Data()))
        XCTAssertNil(IconRenderer.pngPixelSize(Data(repeating: 0, count: 64)))
        XCTAssertFalse(IconRenderer.isPNG(Data([0x89, 0x50])))
    }
}
