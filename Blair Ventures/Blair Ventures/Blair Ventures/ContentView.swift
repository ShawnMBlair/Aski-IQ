import SwiftUI

struct ContentView: View {
    @State private var store = AppStore()

    var body: some View {
        TabView {
            ProjectsView(store: store)
                .tabItem { Label("Projects", systemImage: "folder") }
            CrewView(store: store)
                .tabItem { Label("Crew", systemImage: "person.3") }
            EstimatesView(store: store)
                .tabItem { Label("Estimates", systemImage: "doc.text") }
            SafetyView(store: store)
                .tabItem { Label("Safety", systemImage: "checkmark.shield") }
            ScheduleView(store: store)
                .tabItem { Label("Schedule", systemImage: "calendar") }
        }
    }
}

#Preview { ContentView() }
