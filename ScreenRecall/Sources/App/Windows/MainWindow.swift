import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable, Hashable {
    case overview, timeline, search, reports, todos, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .timeline: return "时间线"
        case .search:   return "检索"
        case .reports:  return "报告"
        case .todos:    return "TODO"
        case .settings: return "设置"
        }
    }
    var systemImage: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .timeline: return "calendar.day.timeline.left"
        case .search:   return "magnifyingglass"
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
            case .timeline: TimelineView()
            case .search:   SearchView()
            case .reports:  ReportsView()
            case .todos:    TodosView()
            case .settings: SettingsView()
            }
        }
    }
}
