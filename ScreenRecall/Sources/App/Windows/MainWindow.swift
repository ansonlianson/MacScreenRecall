import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable, Hashable {
    case overview, recall, reports, todos, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .recall:   return "回溯"
        case .reports:  return "报告"
        case .todos:    return "TODO"
        case .settings: return "设置"
        }
    }
    var systemImage: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .recall:   return "clock.arrow.circlepath"
        case .reports:  return "doc.text"
        case .todos:    return "checklist"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @State private var selection: SidebarTab? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
            .navigationTitle("Screen Recall")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .recall:   RecallView()
            case .reports:  ReportsView()
            case .todos:    TodosView()
            case .settings: SettingsView()
            }
        }
    }
}
