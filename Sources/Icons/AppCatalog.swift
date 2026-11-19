import Foundation
import UIKit

/// An app a custom icon can open, with the link that launches it.
struct CatalogApp: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case apple
        case messaging
        case social
        case media
        case other

        var title: String {
            switch self {
            case .apple: return "Apple apps"
            case .messaging: return "Messaging & calls"
            case .social: return "Social"
            case .media: return "Video, music & games"
            case .other: return "Maps, web & shopping"
            }
        }
    }

    let name: String
    let launchURL: String
    /// SF Symbol shown in the picker row.
    let symbol: String
    let kind: Kind
    /// Extra words that should find this app in search.
    var keywords: [String] = []

    var id: String { name }

    /// The SF Symbol if this iOS version has it, otherwise a generic app symbol.
    var displaySymbol: String {
        UIImage(systemName: symbol) != nil ? symbol : "app.fill"
    }
}

/// Curated apps whose launch links are documented by the vendor or widely
/// reported to work. Anything else can be typed as a custom link in the editor.
enum AppCatalog {
    static let apps: [CatalogApp] = [
        // Apple apps. Only Messages (sms:) and Shortcuts are documented by Apple;
        // the rest are long-standing but private, so "Test link" before installing.
        CatalogApp(name: "Messages", launchURL: "sms:", symbol: "message.fill", kind: .apple, keywords: ["imessage", "sms", "text"]),
        CatalogApp(name: "Phone", launchURL: "mobilephone://", symbol: "phone.fill", kind: .apple, keywords: ["call"]),
        CatalogApp(name: "Mail", launchURL: "message://", symbol: "envelope.fill", kind: .apple, keywords: ["email", "inbox"]),
        CatalogApp(name: "Shortcuts", launchURL: "shortcuts://", symbol: "square.stack.3d.up.fill", kind: .apple),
        CatalogApp(name: "Maps", launchURL: "maps://", symbol: "map.fill", kind: .apple, keywords: ["apple maps", "directions"]),
        CatalogApp(name: "Music", launchURL: "music://", symbol: "music.note", kind: .apple, keywords: ["apple music"]),
        CatalogApp(name: "Photos", launchURL: "photos-redirect://", symbol: "photo.on.rectangle", kind: .apple, keywords: ["pictures", "gallery"]),
        CatalogApp(name: "Settings", launchURL: "App-prefs:", symbol: "gearshape.fill", kind: .apple, keywords: ["preferences"]),
        CatalogApp(name: "Calendar", launchURL: "calshow://", symbol: "calendar", kind: .apple),
        CatalogApp(name: "Notes", launchURL: "mobilenotes://", symbol: "note.text", kind: .apple),
        CatalogApp(name: "Reminders", launchURL: "x-apple-reminderkit://", symbol: "list.bullet", kind: .apple, keywords: ["todo", "tasks"]),
        CatalogApp(name: "App Store", launchURL: "itms-apps://", symbol: "bag.fill", kind: .apple, keywords: ["store"]),
        CatalogApp(name: "Podcasts", launchURL: "podcasts://", symbol: "antenna.radiowaves.left.and.right", kind: .apple),
        CatalogApp(name: "Books", launchURL: "ibooks://", symbol: "book.fill", kind: .apple, keywords: ["ibooks", "reading"]),
        CatalogApp(name: "Clock", launchURL: "clock-alarm://", symbol: "alarm.fill", kind: .apple, keywords: ["alarm"]),
        CatalogApp(name: "Timer", launchURL: "clock-timer://", symbol: "timer", kind: .apple, keywords: ["clock"]),
        CatalogApp(name: "Stopwatch", launchURL: "clock-stopwatch://", symbol: "stopwatch.fill", kind: .apple, keywords: ["clock"]),
        CatalogApp(name: "World Clock", launchURL: "clock-worldclock://", symbol: "globe", kind: .apple, keywords: ["clock", "time zones"]),
        CatalogApp(name: "Files", launchURL: "shareddocuments://", symbol: "folder.fill", kind: .apple, keywords: ["documents"]),
        CatalogApp(name: "Wallet", launchURL: "shoebox://", symbol: "creditcard.fill", kind: .apple, keywords: ["apple pay", "passes"]),
        CatalogApp(name: "Health", launchURL: "x-apple-health://", symbol: "heart.fill", kind: .apple, keywords: ["fitness", "steps"]),
        CatalogApp(name: "Weather", launchURL: "weather://", symbol: "cloud.sun.fill", kind: .apple),
        CatalogApp(name: "Find My", launchURL: "findmy://", symbol: "location.fill", kind: .apple, keywords: ["find my iphone", "airtag"]),
        CatalogApp(name: "Voice Memos", launchURL: "voicememos://", symbol: "waveform", kind: .apple, keywords: ["recorder", "recording"]),

        // Messaging & calls
        CatalogApp(name: "WhatsApp", launchURL: "whatsapp://", symbol: "phone.bubble.left.fill", kind: .messaging),
        CatalogApp(name: "Telegram", launchURL: "tg://", symbol: "paperplane.fill", kind: .messaging),
        CatalogApp(name: "Signal", launchURL: "sgnl://", symbol: "lock.fill", kind: .messaging),
        CatalogApp(name: "Messenger", launchURL: "fb-messenger://", symbol: "bubble.left.fill", kind: .messaging, keywords: ["facebook messenger"]),
        CatalogApp(name: "Discord", launchURL: "discord://", symbol: "headphones", kind: .messaging),
        CatalogApp(name: "Slack", launchURL: "slack://open", symbol: "number", kind: .messaging),
        CatalogApp(name: "Zoom", launchURL: "zoomus://", symbol: "video.fill", kind: .messaging, keywords: ["meeting"]),
        CatalogApp(name: "Snapchat", launchURL: "snapchat://", symbol: "camera.viewfinder", kind: .messaging, keywords: ["snap"]),

        // Social
        CatalogApp(name: "Instagram", launchURL: "instagram://", symbol: "camera.fill", kind: .social, keywords: ["insta", "ig"]),
        CatalogApp(name: "TikTok", launchURL: "snssdk1233://", symbol: "music.note.list", kind: .social),
        CatalogApp(name: "X", launchURL: "twitter://", symbol: "at", kind: .social, keywords: ["twitter"]),
        CatalogApp(name: "Facebook", launchURL: "fb://", symbol: "person.2.fill", kind: .social, keywords: ["fb"]),
        CatalogApp(name: "Threads", launchURL: "barcelona://", symbol: "at.circle.fill", kind: .social, keywords: ["meta"]),
        CatalogApp(name: "Reddit", launchURL: "reddit://", symbol: "text.bubble.fill", kind: .social),
        CatalogApp(name: "Pinterest", launchURL: "pinterest://", symbol: "pin.fill", kind: .social),

        // Video, music & games
        CatalogApp(name: "YouTube", launchURL: "youtube://", symbol: "play.rectangle.fill", kind: .media, keywords: ["video"]),
        CatalogApp(name: "Spotify", launchURL: "spotify://", symbol: "music.quarternote.3", kind: .media, keywords: ["music"]),
        CatalogApp(name: "Netflix", launchURL: "nflx://", symbol: "tv.fill", kind: .media, keywords: ["movies", "series"]),
        CatalogApp(name: "Twitch", launchURL: "twitch://", symbol: "gamecontroller.fill", kind: .media, keywords: ["stream"]),
        CatalogApp(name: "Roblox", launchURL: "roblox://", symbol: "cube.fill", kind: .media, keywords: ["game"]),
        CatalogApp(name: "Duolingo", launchURL: "duolingo://", symbol: "graduationcap.fill", kind: .media, keywords: ["language", "learn"]),

        // Maps, web & shopping
        CatalogApp(name: "Google Maps", launchURL: "comgooglemaps://", symbol: "map", kind: .other, keywords: ["directions"]),
        CatalogApp(name: "Chrome", launchURL: "googlechrome://", symbol: "globe.americas.fill", kind: .other, keywords: ["google chrome", "browser"]),
        CatalogApp(name: "Gmail", launchURL: "googlegmail://", symbol: "envelope.open.fill", kind: .other, keywords: ["google mail", "email"]),
        CatalogApp(name: "Uber", launchURL: "uber://", symbol: "car.fill", kind: .other, keywords: ["taxi", "ride"]),
        CatalogApp(name: "Amazon", launchURL: "com.amazon.mobile.shopping://", symbol: "cart.fill", kind: .other, keywords: ["shopping"]),
        CatalogApp(name: "PayPal", launchURL: "paypal://", symbol: "dollarsign.circle.fill", kind: .other, keywords: ["pay", "money"]),
    ]

    /// Apps whose name, link or keywords contain `query` (case-insensitive).
    /// An empty query returns every app.
    static func search(_ query: String) -> [CatalogApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(needle)
                || app.launchURL.localizedCaseInsensitiveContains(needle)
                || app.keywords.contains(where: { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    /// The catalog app whose launch link is exactly `launchURL`, if any.
    static func app(matching launchURL: String) -> CatalogApp? {
        let normalized = launchURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return apps.first { $0.launchURL.lowercased() == normalized }
    }
}
