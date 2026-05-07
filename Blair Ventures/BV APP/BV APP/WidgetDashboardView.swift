// WidgetDashboardView.swift
// BV APP – Modular, customizable widget dashboard

import SwiftUI

// MARK: - Widget Dashboard View

struct WidgetDashboardView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var layout = DashboardLayoutManager()
    @State private var isEditing    = false
    @State private var showLibrary  = false
    @State private var showChat     = false
    @State private var showCRMPanel = false
    @State private var crmPanelTab  = 0
    @State private var crmSheet: CRMPanelSheet? = nil
    @State private var showUniversalSearch = false

    private let columns  = 2           // 2 cards per row
    private let spacing: CGFloat = 14

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: spacing) {
                    let rows = pairedRows()
                    ForEach(rows.indices, id: \.self) { i in
                        rowView(rows[i])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                if showCRMPanel {
                    crmPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer().frame(height: 120)
            }
            .navigationTitle("Dashboard")
            .toolbar { toolbarItems }
            .sheet(isPresented: $showLibrary) {
                WidgetLibraryView(layout: layout).environmentObject(store)
            }
            .sheet(isPresented: $showChat) {
                AIChatView().environmentObject(store)
            }
            .sheet(isPresented: $showUniversalSearch) {
                UniversalSearchSheet().environmentObject(store)
            }
            .onAppear { layout.ensureLayout(for: store.currentUserRole) }
            .overlay(alignment: .bottomTrailing) { aiButton }
            .sheet(item: $crmSheet) { sheet in
                crmSheetDestination(for: sheet)
            }
        }
    }

    // MARK: - Layout: pair widgets into rows of 2

    private func pairedRows() -> [[DashboardWidget]] {
        let visible = layout.widgets.filter(\.isVisible).sorted { $0.position < $1.position }
        var rows: [[DashboardWidget]] = []
        var i = 0
        while i < visible.count {
            let w = visible[i]
            if w.size == .wide || w.size == .large {
                rows.append([w])
                i += 1
            } else {
                if i + 1 < visible.count && visible[i + 1].size != .wide && visible[i + 1].size != .large {
                    rows.append([w, visible[i + 1]])
                    i += 2
                } else {
                    rows.append([w])
                    i += 1
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: [DashboardWidget]) -> some View {
        if row.count == 1, let w = row.first {
            WidgetContainerView(
                widget: w,
                isEditing: isEditing,
                onRemove: { layout.removeWidget(id: w.id) },
                onResize: { size in layout.resizeWidget(id: w.id, to: size) },
                onSwap:   { src in layout.swapWidgets(sourceID: src, targetID: w.id) }
            )
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight(w))
        } else {
            HStack(spacing: spacing) {
                ForEach(row) { w in
                    WidgetContainerView(
                        widget: w,
                        isEditing: isEditing,
                        onRemove: { layout.removeWidget(id: w.id) },
                        onResize: { size in layout.resizeWidget(id: w.id, to: size) },
                        onSwap:   { src in layout.swapWidgets(sourceID: src, targetID: w.id) }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: cardHeight(w))
                }
            }
        }
    }

    private func cardHeight(_ w: DashboardWidget) -> CGFloat {
        switch w.size {
        case .small:  return 200   // half-width: KPI header + 3 list rows
        case .wide:   return 190   // full-width, short: horizontal KPI layouts (revenue, forecast)
        case .tall:   return 370   // half-width, tall: KPI header + 5–6 list rows
        case .large:  return 340   // full-width, tall: rich content (schedule, recent activity)
        }
    }

    // MARK: - Floating AI button

    private var aiButton: some View {
        Button { showChat = true } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.purple)
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isEditing {
                Button {
                    showLibrary = true
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    layout.reset(for: store.currentUserRole)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                Button("Done") {
                    withAnimation { isEditing = false }
                }
                .bold()
            } else {
                Button {
                    showUniversalSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search clients, projects, quotes, and more")
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showCRMPanel.toggle()
                    }
                } label: {
                    Image(systemName: showCRMPanel
                          ? "person.crop.rectangle.stack.fill"
                          : "person.crop.rectangle.stack")
                    .foregroundColor(showCRMPanel ? .accentColor : .primary)
                }
                Button {
                    withAnimation { isEditing = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    // MARK: - Inline CRM Panel

    private var crmPanel: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .foregroundStyle(.tint)
                Text("CRM")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showCRMPanel = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))

            // Tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(crmPanelTabs.indices, id: \.self) { i in
                        let tab = crmPanelTabs[i]
                        Button {
                            withAnimation { crmPanelTab = i }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(tab.label)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundColor(crmPanelTab == i ? .accentColor : .secondary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                            .overlay(
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundColor(crmPanelTab == i ? .accentColor : .clear),
                                alignment: .bottom
                            )
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))

            Divider()

            // Panel content
            crmPanelContent
        }
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private let crmPanelTabs: [(label: String, icon: String)] = [
        ("Dashboard", "sparkles"),
        ("Companies", "building.2.fill"),
        ("Pipeline",  "chart.bar.fill"),
        ("Tasks",     "checklist"),
        ("Reports",   "chart.bar.xaxis")
    ]

    @ViewBuilder
    private var crmPanelContent: some View {
        switch crmPanelTab {
        case 0:
            CRMDashboardInlineView()
                .environmentObject(store)
        case 1:
            Button { crmSheet = .companies } label: {
                CRMPanelNavRow(label: "Companies", icon: "building.2.fill",
                               subtitle: "\(store.clients.count) companies")
            }
            .buttonStyle(.plain)
            .padding(16)
        case 2:
            Button { crmSheet = .pipeline } label: {
                CRMPanelNavRow(label: "Pipeline", icon: "chart.bar.fill",
                               subtitle: "\(store.openOpportunities.count) open opportunities")
            }
            .buttonStyle(.plain)
            .padding(16)
        case 3:
            Button { crmSheet = .tasks } label: {
                CRMPanelNavRow(label: "Tasks", icon: "checklist",
                               subtitle: "\(store.crmTasks.filter { $0.status != .done }.count) open tasks")
            }
            .buttonStyle(.plain)
            .padding(16)
        case 4:
            Button { crmSheet = .reports } label: {
                CRMPanelNavRow(label: "Reports", icon: "chart.bar.xaxis",
                               subtitle: "Revenue forecasting & pipeline reports")
            }
            .buttonStyle(.plain)
            .padding(16)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func crmSheetDestination(for sheet: CRMPanelSheet) -> some View {
        switch sheet {
        case .companies: CRMCompanyListView().environmentObject(store)
        case .pipeline:  CRMPipelineView().environmentObject(store)
        case .tasks:     CRMTaskListView().environmentObject(store)
        case .reports:   CRMReportsView().environmentObject(store)
        }
    }
}

enum CRMPanelSheet: Identifiable {
    case companies, pipeline, tasks, reports
    var id: Self { self }
}

private struct CRMPanelNavRow: View {
    let label: String
    let icon: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Widget Container

struct WidgetContainerView: View {
    let widget:    DashboardWidget
    let isEditing: Bool
    let onRemove:  () -> Void
    let onResize:  (WidgetSize) -> Void
    let onSwap:    (UUID) -> Void

    @EnvironmentObject var store: AppStore
    @State private var isDropTarget = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.blue.opacity(isDropTarget ? 0.7 : 0), lineWidth: 2)
                )

            if isEditing { editBadge }
        }
        .animation(.easeInOut(duration: 0.15), value: isEditing)
        .draggable(widget.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard isEditing,
                  let src = items.first.flatMap({ UUID(uuidString: $0) }),
                  src != widget.id else { return false }
            onSwap(src)
            return true
        } isTargeted: { isDropTarget = $0 && isEditing }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: widget.type.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(widgetAccent)
                Text(widget.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if isEditing {
                    Menu {
                        ForEach(widget.type.supportedSizes, id: \.self) { size in
                            Button {
                                onResize(size)
                            } label: {
                                Label(
                                    size.displayName,
                                    systemImage: widget.size == size ? "checkmark" : size.icon
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 8)

            WidgetContent(widget: widget)
                .environmentObject(store)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        .clipped()
    }

    private var editBadge: some View {
        Button(action: onRemove) {
            ZStack {
                Circle().fill(Color.red).frame(width: 22, height: 22)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .offset(x: 8, y: -8)
        .transition(.scale.combined(with: .opacity))
    }

    private var widgetAccent: Color {
        switch widget.type {
        case .todaysSchedule:  return .blue
        case .activeProjects:  return .blue
        case .estimatesDue:    return .purple
        case .crewStatus:      return .orange
        case .safetyForms:     return .red
        case .openRFIs:        return .orange
        case .revenueSnapshot: return .green
        case .weather:         return .cyan
        case .mapView:         return .teal
        case .recentActivity:  return .indigo
        case .crmTasks:        return .blue
        case .pipelineSummary: return .indigo
        case .forecastSnapshot:return .green
        }
    }
}
