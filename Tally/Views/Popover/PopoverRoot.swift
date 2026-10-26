import AppKit
import SwiftUI

struct PopoverRoot: View {
    @Bindable var store: TallyStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showConnect = false

    var body: some View {
        Group {
            if store.showsConnectForm || showConnect {
                SignInView(store: store, dismiss: showConnect ? { showConnect = false } : nil)
            } else if store.gatewayEnabled {
                switch store.phase {
                case .signedOut:
                    subscriptionPopover
                case .loading:
                    LoadingUsageView()
                case .failed:
                    FailedUsageView(store: store)
                case .empty:
                    EmptyUsageView(store: store)
                case .live:
                    livePopover
                }
            } else {
                subscriptionPopover
            }
        }
        .onChange(of: store.isSignedIn) { _, signedIn in
            if signedIn { showConnect = false }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .onAppear {
            if store.phase == .live, store.layout == .compact, store.shouldPresentAlert {
                store.layout = .alert
            }
        }
    }

    @ViewBuilder
    private var livePopover: some View {
        switch store.layout {
        case .compact:
            CompactPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        case .alert:
            AlertPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        case .detailed:
            DetailedPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        }
    }

    private var subscriptionPopover: some View {
        CompactPopover(
            store: store,
            openHistory: openHistory,
            openSettings: showSettings,
            connectGateway: store.gatewayEnabled && !store.isSignedIn ? { showConnect = true } : nil
        )
    }

    private func openHistory() {
        NSApp.activate()
        openWindow(id: TallyWindow.history)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
