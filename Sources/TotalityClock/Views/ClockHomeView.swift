import SwiftUI
import TotalityUI

/// The Clock (issue 204): World, Alarms, Timers and Stopwatch, as the approved mockup draws them.
public struct ClockHomeView: View {
    private let model: ClockModel
    private let onClose: (() -> Void)?
    @State private var tab: ClockModel.Tab = .alarms
    @Environment(\.scenePhase) private var scenePhase

    public init(model: ClockModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            header
            switch model.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Opening the Clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ClockEmpty(
                    title: "The Clock couldn't open",
                    detail: "Its records on this iPhone couldn't be read. Sign in, then open the Clock again.",
                    button: nil
                )
                .padding(Space.s4)
                Spacer()
            case .ready:
                Group {
                    switch tab {
                    case .world: WorldClockView(model: model)
                    case .alarms: AlarmsView(model: model)
                    case .timers: TimersView(model: model)
                    case .stopwatch: StopwatchView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(theme.bg.color)
        .task { if model.phase == .loading { await model.load() } }
        .onAppear(perform: takeRequest)
        .onChange(of: model.requestedTab) { takeRequest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAccess() } }
        }
        .alert("Clock", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private func takeRequest() {
        guard let requested = model.requestedTab else { return }
        tab = requested
        model.requestedTab = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if let onClose {
                    HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle("Clock")
            if model.phase == .ready {
                ClockTabs(selection: $tab)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
    }
}
