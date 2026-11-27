import SwiftUI
import TotalityCore
import TotalityUI

/// A card's #tags as buttons. A card's own tap opens the post and sits over its text, so a link inside the
/// text would never be reached; a button of its own is, and opens that tag's posts.
struct TagLine: View {
    let model: SocialModel
    let tags: [String]

    var body: some View {
        let theme = Theme.current
        if !tags.isEmpty {
            HStack(spacing: Space.s2) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    Button { model.showTag(tag) } label: {
                        Text("#" + tag).font(Typeface.caption).foregroundStyle(theme.accent.color).lineLimit(1)
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityLabel("Tag \(tag)")
                    .accessibilityHint("Shows posts with this tag.")
                }
                Spacer(minLength: 0)
            }
        }
    }
}
