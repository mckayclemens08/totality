import SwiftUI
import TotalityUI

/// Every open tab, to switch to or close.
struct WebTabsView: View {
    let model: WebModel
    let onClose: () -> Void

    var body: some View {
        WebSheet(title: model.tabs.count == 1 ? "1 tab" : "\(model.tabs.count) tabs", onClose: onClose) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: Space.s3) {
                        ForEach(model.tabs) { row($0) }
                    }
                    .padding(Space.s4)
                }
                HStack(spacing: Space.s5) {
                    Button("New Tab") {
                        model.newTab()
                        onClose()
                    }
                    Button("New Private Tab") {
                        model.newTab(isPrivate: true)
                        onClose()
                    }
                }
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.accent.color)
                .buttonStyle(.plain)
                .padding(Space.s4)
            }
        }
    }

    private func row(_ tab: WebTab) -> some View {
        let theme = Theme.current
        let isCurrent = tab.id == model.currentID
        return HStack(spacing: Space.s3) {
            Button {
                model.select(tab)
                onClose()
            } label: {
                HStack(spacing: Space.s3) {
                    Image(systemName: tab.isPrivate ? "eye.slash" : "globe")
                        .font(Typeface.body)
                        .foregroundStyle(isCurrent ? theme.accent.color : theme.textSecondary.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tab.title)
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        if let site = tab.address?.host() ?? tab.page?.url?.host() {
                            Text(site)
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.isPrivate ? "Private tab, \(tab.title)" : tab.title)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            Button {
                model.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s7, height: Space.s7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.leading, Space.s4)
        .padding(.vertical, Space.s1)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}
