import SwiftUI

struct RootView: View {
    @State private var selection: Tab = .single

    enum Tab: Hashable { case single, pack }

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem { Label("Cutout", systemImage: "scissors") }
                .tag(Tab.single)
            PackBuilderView()
                .tabItem { Label("Pack", systemImage: "square.grid.3x3.fill") }
                .tag(Tab.pack)
        }
    }
}
