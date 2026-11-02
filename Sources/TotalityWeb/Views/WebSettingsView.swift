import SwiftUI
import TotalityUI

struct WebSettingsView: View {
    let model: WebModel
    let onClose: () -> Void

    @AppStorage(SafeSearch.key) private var safety = SafeSearch.moderate.rawValue
    @State private var clearingSites = false
    @State private var clearedSites = false

    var body: some View {
        let theme = Theme.current
        WebSheet(title: "Web Settings", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Safe search")
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                        Picker("Safe search", selection: $safety) {
                            ForEach(SafeSearch.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Sign-ins and site data")
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                        Text("Sites keep you signed in in normal tabs. This data stays on this device and is protected by the device's own encryption, not by your Totality key.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                        Button(clearedSites ? "Cleared" : "Sign Out of All Sites") { clearingSites = true }
                            .font(Typeface.callout)
                            .foregroundStyle(theme.accent.color)
                            .buttonStyle(.plain)
                            .disabled(clearedSites)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s4)
            }
        }
        .confirmationDialog("Sign out of all sites?", isPresented: $clearingSites, titleVisibility: .visible) {
            Button("Sign Out of All Sites", role: .destructive) {
                Task {
                    await model.clearSiteData()
                    clearedSites = true
                }
            }
        } message: {
            Text("This removes cookies and site data for your normal tabs on this device.")
        }
    }
}
