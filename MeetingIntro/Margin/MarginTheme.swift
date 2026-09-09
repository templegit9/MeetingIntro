import SwiftUI

/// Margin's palette. **Its own brand**, so nothing here reads from MeetingIntro's accent
/// or its dark chrome — a Margin page looks the same whatever the host app is doing.
///
/// The spec's rule about skeuomorphism is a constraint, not a mood: cream paper and green
/// cloth appear **only** on the cover and the pages. No leather, no stitching, no drop
/// caps, and page text stays near-black on cream at the same sizes as normal UI, because
/// the paper look must never cost contrast.
enum MarginTheme {
    /// Cloth cover.
    static let cloth = Color(red: 0.184, green: 0.420, blue: 0.290)      // #2F6B4A
    static let clothDark = Color(red: 0.133, green: 0.188, blue: 0.122)  // #22301F
    /// Paper.
    static let paper = Color(red: 0.965, green: 0.953, blue: 0.918)      // #F6F3EA
    static let rule = Color(red: 0.847, green: 0.827, blue: 0.769)       // faint ruled line
    /// Ink. Near-black on cream — contrast first.
    static let ink = Color(red: 0.106, green: 0.145, blue: 0.114)
    static let inkSoft = Color(red: 0.290, green: 0.352, blue: 0.302)
    /// The ribbon: amber when something is waiting.
    static let ribbon = Color(red: 0.878, green: 0.353, blue: 0.290)     // resting red-clay
    static let ribbonAmber = Color(red: 0.753, green: 0.482, blue: 0.071)
    static let amberInk = Color(red: 0.659, green: 0.388, blue: 0.165)

    /// Closed size, from the spec.
    static let coverSize = CGSize(width: 44, height: 38)
    /// Open width. Height follows the content.
    static let openWidth: CGFloat = 320
    /// How far from the screen corner it rests.
    static let inset: CGFloat = 18
}
