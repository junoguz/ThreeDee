//
//  ThreeDeeApp.swift
//  ThreeDee
//
//  Created by junoguz on 18.11.26.
//

import SwiftUI

@main
struct ThreeDeeApp: App {
    @State private var settings = AppSettings()
    @State private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(store)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Palette.ink)
                .fontDesign(.rounded)
        }
    }
}

struct RootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(path: $path)
                .navigationDestination(for: String.self) { fileName in
                    if let item = store.item(named: fileName) {
                        ViewerScreen(item: item)
                    } else {
                        FailureView(message: "This file is no longer in the library.") { path.removeAll() }
                    }
                }
        }
        // Files opened from other apps (Files, AirDrop, Mail, share sheet).
        .onOpenURL { url in
            Task {
                let imported = await store.importFiles([url], settings: settings)
                if let first = imported.first { path = [first.fileName] }
            }
        }
        #if DEBUG
        .task { openFromLaunchArguments() }
        #endif
    }

    #if DEBUG
    /// `-open <file name prefix>` opens a library item at launch (UI testing / screenshots).
    private func openFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-open"), i + 1 < args.count else { return }
        let prefix = args[i + 1]
        if let item = store.items.first(where: { $0.fileName.hasPrefix(prefix) }) { path = [item.fileName] }
    }
    #endif
}
