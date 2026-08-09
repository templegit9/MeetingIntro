import SwiftUI

/// The character that rides at the head of the crawl, dragging the text behind it.
///
/// It's part of the scrolling strip (not pinned to an edge), so it enters from the right
/// with its train of items in tow and hauls them off to the left — which is what makes it
/// read as *pulling* rather than just sitting there.
///
/// **Emoji orientation matters:** the crawl travels right-to-left, so a leader has to face
/// left to look like it's pulling. Apple's emoji for vehicles and animals almost all face
/// left already; the few that don't (rocket, UFO) are omnidirectional enough not to care.
/// If you add a right-facing glyph, flip it with `.scaleEffect(x: -1)` rather than
/// shipping a character that appears to be pushing the text backwards.
enum TickerLeader: String, CaseIterable, Identifiable {
    case none
    case train
    case truck
    case rocket
    case runner
    case cat
    case dog
    case snail
    case turtle
    case ant
    case bee
    case horse
    case dino
    case ghost
    case robot
    case ufo
    case newspaper
    case megaphone
    case hare
    case tortoise
    case sparkle

    var id: String { rawValue }

    /// What the picker shows.
    var displayName: String {
        switch self {
        case .none:      return "None — just the status icons"
        case .train:     return "Steam train"
        case .truck:     return "Delivery truck"
        case .rocket:    return "Rocket"
        case .runner:    return "Runner"
        case .cat:       return "Cat"
        case .dog:       return "Dog"
        case .snail:     return "Snail"
        case .turtle:    return "Turtle"
        case .ant:       return "Ant"
        case .bee:       return "Bee"
        case .horse:     return "Racehorse"
        case .dino:      return "Dinosaur"
        case .ghost:     return "Ghost"
        case .robot:     return "Robot"
        case .ufo:       return "Flying saucer"
        case .newspaper: return "Newsroom"
        case .megaphone: return "Megaphone"
        case .hare:      return "Hare"
        case .tortoise:  return "Tortoise"
        case .sparkle:   return "Sparkles"
        }
    }

    /// The emoji character, or nil for the SF Symbol styles.
    var emoji: String? {
        switch self {
        case .none, .hare, .tortoise, .sparkle: return nil
        case .train:     return "🚂"
        case .truck:     return "🚚"
        case .rocket:    return "🚀"
        case .runner:    return "🏃"
        case .cat:       return "🐈"
        case .dog:       return "🐕"
        case .snail:     return "🐌"
        case .turtle:    return "🐢"
        case .ant:       return "🐜"
        case .bee:       return "🐝"
        case .horse:     return "🐎"
        case .dino:      return "🦖"
        case .ghost:     return "👻"
        case .robot:     return "🤖"
        case .ufo:       return "🛸"
        case .newspaper: return "📰"
        case .megaphone: return "📣"
        }
    }

    /// SF Symbol for the styles that stay native rather than emoji.
    var symbol: String? {
        switch self {
        case .hare:     return "hare.fill"
        case .tortoise: return "tortoise.fill"
        case .sparkle:  return "sparkles"
        default:        return nil
        }
    }

    /// A one-line sample for the picker: glyph + a stand-in for the text it's hauling.
    var samplePreview: String {
        guard let emoji else { return displayName }
        return "\(emoji) ⟵ text"
    }

    var isNone: Bool { self == .none }
}

/// Everything about how the strip *looks*, bundled so the window controller can diff it
/// in one comparison and only rebuild the view when something actually changed.
struct TickerStyle: Equatable {
    var leader: TickerLeader = .none
    /// Keep the per-item status glyphs (the coloured circles). Turning this off leaves
    /// the leader as the only glyph — a cleaner, all-text crawl.
    var showItemIcons: Bool = true
    /// Gentle vertical bob on the leader, so a walking/running character looks alive.
    var bounce: Bool = true
    var speed: Double = 40
}
