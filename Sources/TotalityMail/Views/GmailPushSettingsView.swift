import SwiftUI
import TotalityUI

/// Instant Gmail sync's two settings, for this device. Off, Gmail refreshes on the usual schedule.
struct GmailPushSettingsView: View {
    @State private var isOn = GmailPushSettings.shared.isOn
    @State private var showsDetails = GmailPushSettings.shared.showsDetails

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Toggle("Instant Gmail", isOn: $isOn)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .onChange(of: isOn) { _, on in GmailPushSettings.shared.isOn = on }
            Text(isOn ? OutsideWording.instantOn : OutsideWording.instantOff)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if isOn {
                Picker("Notifications show", selection: $showsDetails) {
                    Text("Sender and subject").tag(true)
                    Text("“New mail” only").tag(false)
                }
                .pickerStyle(.menu)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .onChange(of: showsDetails) { _, details in GmailPushSettings.shared.showsDetails = details }
            }
        }
        .padding(Space.s3)
    }
}
