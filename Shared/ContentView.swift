import SwiftUI
import MapKit
import CoreLocation
import AtlasCore

struct ContentView: View {
    @ObservedObject var tabs: AtlasTabs
    @ObservedObject var map: MapViewModel

    @State private var reflexServer: ReflexServer?
    @State private var selection: AtlasSelection?
    @State private var walkOverlays: [WalkOverlay] = []
    @State private var routeDistances: [UUID: Double] = [:]
    @State private var cachedCards: [AtlasCard] = []
    @State private var cachedCardsKey = ""
    @State private var dataRevision = 0
    @State private var searchText = ""
    @State private var placeQuery = ""
    @State private var placeSearchTask: Task<Void, Never>?
    @State private var sidebarCollapsed = false
    @State private var sidebarOpen = false
    /// Live horizontal drag on the phone drawer; negative is towards closed.
    @State private var drawerDrag: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var placeQueryFocused: Bool

    init(tabs: AtlasTabs) {
        _tabs = ObservedObject(wrappedValue: tabs)
        _map = ObservedObject(wrappedValue: tabs.map)
    }

    private var feature: AtlasFeature {
        AtlasFeature(rawValue: tabs.selected) ?? .walks
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 840
            if compact {
                compactLayout(width: proxy.size.width)
            } else {
                HStack(spacing: 0) {
                    if sidebarCollapsed {
                        collapsedRail
                    } else {
                        sidebar(width: 302, compact: false)
                    }
                    mapArea(compact: false)
                }
            }
        }
        .background {
            AtlasTheme.background
            #if os(macOS)
            WindowChrome()
            #endif
        }
        .preferredColorScheme(.dark)
        .task { await bootstrap() }
        .task(id: tabs.selected) {
            if feature == .cameras { await tabs.cameras.refreshIfNeeded() }
        }
        .task(id: cardsKey) { refreshCards() }
        .task(id: tabs.walks.walks.map(\.id)) { await loadRoutes() }
        .onChange(of: tabs.selected) { _, _ in
            selection = nil
            searchText = ""
            placeQuery = ""
            tabs.places.clearResults()
            focusActive(animated: false)
        }
        .onChange(of: selection) { _, newValue in
            // Deselecting must not move the camera: closing a card should
            // leave you looking at the thing you just closed.
            if let newValue { focusSelection(newValue) }
        }
        .onChange(of: tabs.cameras.cameras.count) { _, _ in
            if feature == .cameras, selection == nil { focusActive(animated: false) }
        }
        .onAppear { startReflexServer() }
    }

    // MARK: - Layout

    /// The map keeps the full canvas; the sidebar is a real column, so the
    /// list scrolls vertically and search has somewhere to live.
    private func mapArea(compact: Bool, overlay: Bool = true) -> some View {
        ZStack(alignment: .topLeading) {
            AtlasMapCanvas(
                tabs: tabs,
                map: map,
                feature: feature,
                selection: selection,
                walkOverlays: walkOverlays,
                focusFlightID: focusFlight?.id,
                onSelect: select
            )
            .ignoresSafeArea()

            vignette

            if overlay {
                VStack(spacing: 0) {
                    // Top chrome: the drawer handle sits opposite the map
                    // controls, so the lower half of the map stays clear.
                    HStack(alignment: .top, spacing: 10) {
                        if compact {
                            Button(action: toggleDrawer) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .frame(width: 38, height: 38)
                                    .glass(radius: 13, tint: feature.accent, strength: 0.66)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open sidebar")
                        }
                        Spacer(minLength: 2)
                        controls
                    }

                    Spacer(minLength: 0)

                    // The hero lives at the bottom, where a thumb already is.
                    HStack(alignment: .bottom, spacing: 10) {
                        if feature == .cameras, let camera = selectedCamera {
                            CameraMonitor(
                                camera: camera,
                                compact: compact,
                                onLocate: { focusSelection(selection, force: true) },
                                onClose: { selection = nil }
                            )
                        } else {
                            hero(compact: compact)
                        }
                        Spacer(minLength: 2)
                    }
                }
                .padding(compact ? 12 : 18)
                #if os(macOS)
                .padding(.top, 24)
                #endif
            }
        }
    }

    private func compactLayout(width: CGFloat) -> some View {
        let drawerWidth = min(340, width * 0.9)
        // Dimming follows the finger, so a half-dragged drawer sits over a
        // half-lit map instead of snapping.
        let closing = min(1, max(0, -drawerDrag / max(drawerWidth, 1)))

        return ZStack(alignment: .leading) {
            mapArea(compact: true, overlay: !sidebarOpen)

            if sidebarOpen {
                Color.black.opacity(0.44 * (1 - closing))
                    .ignoresSafeArea()
                    .onTapGesture(perform: toggleDrawer)
                    .transition(.opacity)

                drawer(width: drawerWidth)
                    .transition(.move(edge: .leading))
                    .offset(x: drawerDrag)
                    .overlay(alignment: .trailing) {
                        // Drag rail: the scroll view owns gestures over the
                        // list, and a left drawer has no room to be dragged
                        // further left from its own leading edge, so closing
                        // by swipe lives on the panel's free edge.
                        Color.clear
                            .frame(width: 30)
                            .contentShape(Rectangle())
                            .gesture(drawerDismiss(drawerWidth))
                    }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sidebarOpen)
    }

    /// Swipe the panel's leading edge left to dismiss it. The gesture lives on
    /// a rail rather than the whole panel so the card list still scrolls.
    private func drawerDismiss(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                drawerDrag = min(0, value.translation.width)
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.width
                let closes = projected < -width * 0.4 || value.translation.width < -width * 0.25
                withAnimation(.snappy(duration: 0.28)) {
                    drawerDrag = 0
                    if closes { sidebarOpen = false }
                }
            }
    }

    private func toggleDrawer() {
        withAnimation(.snappy(duration: 0.26)) {
            drawerDrag = 0
            sidebarOpen.toggle()
        }
    }


    // MARK: - Chrome

    private var vignette: some View {
        ZStack {
            AtlasTheme.background.opacity(0.14)
            LinearGradient(
                stops: [
                    .init(color: AtlasTheme.background.opacity(0.72), location: 0.0),
                    .init(color: .clear, location: 0.24),
                    .init(color: .clear, location: 0.58),
                    .init(color: AtlasTheme.background.opacity(0.82), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Sidebar

    private func sidebarBody(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader(compact: compact)
            sectionsGrid
                .padding(.top, 16)
            searchField
                .padding(.top, 14)
            if feature == .places {
                placeFinder
                    .padding(.top, 8)
            }
            listHeader
                .padding(.top, 16)
            cardList(compact: compact)
                .padding(.top, 4)
            sidebarFooter
        }
        .padding(.horizontal, 14)
        #if os(macOS)
        .padding(.top, 32)
        .padding(.bottom, 14)
        #else
        .padding(.top, compact ? 18 : 24)
        .padding(.bottom, 14)
        #endif
    }

    private func sidebar(width: CGFloat, compact: Bool) -> some View {
        sidebarBody(compact: compact)
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sidebarBackground)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(AtlasTheme.hairline)
                    .frame(width: 1)
                    .ignoresSafeArea(edges: .vertical)
            }
    }

    /// The phone drawer. A floating glass panel inset from the screen edges,
    /// the way a sheet sits in this design system, instead of an opaque column
    /// welded to the side of the display.
    private func drawer(width: CGFloat) -> some View {
        sidebarBody(compact: true)
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            // Thin enough that the map reads through the panel, dark enough
            // that 11pt body text stays legible over it.
            .glass(radius: 30, tint: feature.accent, strength: 0.44)
            .overlay(alignment: .top) {
                // A sheen along the top edge: the cue that says glass rather
                // than a dark rectangle.
                LinearGradient(
                    colors: [Color.white.opacity(0.07), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(.vertical, 8)
            .padding(.leading, 8)
    }

    private var sidebarBackground: some View {
        ZStack {
            Rectangle().fill(AtlasTheme.background)
            LinearGradient(
                colors: [feature.accent.opacity(0.07), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private func sidebarHeader(compact: Bool) -> some View {
        HStack(spacing: 10) {
            monogram
            VStack(alignment: .leading, spacing: 1) {
                Text("Atlas")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("GEO ARCHIVE")
                    .font(.system(size: 7, weight: .black))
                    .tracking(1.8)
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            Spacer(minLength: 0)
            Button {
                if compact {
                    toggleDrawer()
                } else {
                    withAnimation(.snappy(duration: 0.24)) { sidebarCollapsed = true }
                }
            } label: {
                Image(systemName: compact ? "xmark" : "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(compact ? "Close sidebar" : "Collapse sidebar")
        }
    }

    private var sectionsGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
            spacing: 6
        ) {
            ForEach(AtlasFeature.allCases) { item in
                Button { selectFeature(item) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.title.uppercased())
                            .font(.system(size: 7, weight: .black))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(item == feature ? Color.black : Color.white.opacity(0.58))
                    .background(
                        item == feature ? AnyShapeStyle(item.accent) : AnyShapeStyle(Color.white.opacity(0.045)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(searchFocused ? 0.6 : 0.34))
            TextField("Search \(feature.title.lowercased())", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(searchFocused ? feature.accent.opacity(0.45) : AtlasTheme.hairline, lineWidth: 1)
        }
    }

    /// The Apple Maps finder. Only the Places section has one: it asks Apple
    /// for places that are not in the archive yet and saves the ones worth
    /// keeping.
    private var placeFinder: some View {
        HStack(spacing: 7) {
            Image(systemName: "map.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(placeQueryFocused ? 0.65 : 0.34))
            TextField("Search Apple Maps", text: $placeQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white)
                .focused($placeQueryFocused)
                .autocorrectionDisabled()
                .noAutoCapitalisation()
                .submitLabel(.search)
                .onSubmit { Task { await runPlaceSearch() } }
                .onChange(of: placeQuery) { _, _ in schedulePlaceSearch() }
                .accessibilityIdentifier("atlas.placeSearch")
            if tabs.places.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else if !placeQuery.isEmpty {
                Button {
                    placeQuery = ""
                    tabs.places.clearResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear place search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(AtlasTheme.rose.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(placeQueryFocused ? AtlasTheme.rose.opacity(0.5) : AtlasTheme.hairline, lineWidth: 1)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Text(listHeaderTitle)
                .font(.system(size: 7.5, weight: .black))
                .tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.34))
            Spacer(minLength: 0)
            Text("\(listHeaderCount)")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.34))
        }
    }

    private var showingSearchResults: Bool {
        feature == .places && !tabs.places.results.isEmpty
    }

    private var listHeaderTitle: String {
        if showingSearchResults { return "APPLE MAPS" }
        return searchText.isEmpty ? feature.title.uppercased() : "RESULTS"
    }

    private var listHeaderCount: Int {
        showingSearchResults ? tabs.places.results.count : visibleCards.count
    }

    private func cardList(compact: Bool) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    if showingSearchResults {
                        searchResultRows
                    } else if visibleCards.isEmpty {
                        emptyList
                    } else {
                        ForEach(visibleCards) { card in
                            AtlasRowView(
                                card: card,
                                accent: feature.accent,
                                isSelected: selection == card.selection
                            ) {
                                select(card.selection)
                                if compact { toggleDrawer() }
                            }
                            .id(card.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { _, newValue in
                guard let newValue,
                      let card = visibleCards.first(where: { $0.selection == newValue }) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    scroll.scrollTo(card.id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Apple's results, each with a save control.
    private var searchResultRows: some View {
        ForEach(tabs.places.results) { result in
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AtlasTheme.rose.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(AtlasTheme.rose.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(result.address.isEmpty ? result.category : result.address)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AtlasTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await tabs.places.save(result: result) }
                } label: {
                    Image(systemName: tabs.places.isSaved(result) ? "checkmark" : "plus")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(tabs.places.isSaved(result) ? Color.black : Color.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(
                            tabs.places.isSaved(result) ? AnyShapeStyle(AtlasTheme.rose) : AnyShapeStyle(Color.white.opacity(0.07)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tabs.places.isSaved(result) ? "Saved \(result.name)" : "Save \(result.name)")
                .accessibilityIdentifier("atlas.savePlace")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
    }

    /// Debounced search: typing should not fire a request per keystroke.
    @MainActor
    private func schedulePlaceSearch() {
        placeSearchTask?.cancel()
        let query = placeQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tabs.places.clearResults()
            return
        }
        placeSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runPlaceSearch()
        }
    }

    @MainActor
    private func runPlaceSearch() async {
        placeSearchTask?.cancel()
        let query = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            tabs.places.clearResults()
            return
        }
        await tabs.places.search(query, near: map.state.region.center)
    }

    private var emptyList: some View {
        Text(searchText.isEmpty ? emptyListText : "No matches for “\(searchText)”.")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AtlasTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(AtlasTheme.hairline)
                .frame(height: 1)
            HStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text("On-device archive")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text(footerStatus)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 10)
    }

    private var collapsedRail: some View {
        VStack(spacing: 7) {
            monogram
                .padding(.bottom, 6)

            ForEach(AtlasFeature.allCases) { item in
                Button { selectFeature(item) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(item.title.uppercased())
                            .font(.system(size: 6.5, weight: .black))
                            .tracking(0.4)
                    }
                    .frame(width: 54, height: 48)
                    .foregroundStyle(item == feature ? Color.black : Color.white.opacity(0.55))
                    .background(
                        item == feature ? AnyShapeStyle(item.accent) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 10)

            Button {
                withAnimation(.snappy(duration: 0.24)) { sidebarCollapsed = false }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand sidebar")
        }
        .padding(.horizontal, 8)
        .padding(.top, 32)
        .padding(.bottom, 16)
        .frame(width: 70)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AtlasTheme.hairline)
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
        }
    }

    private var monogram: some View {
        Text("A")
            .font(.system(size: 18, weight: .black, design: .rounded))
            .foregroundStyle(Color.black)
            .frame(width: 36, height: 36)
            .background(
                LinearGradient(colors: [AtlasTheme.lime, AtlasTheme.cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: AtlasTheme.lime.opacity(0.55), radius: 12)
    }

    private func hero(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 7) {
                LiveDot(color: feature.accent)
                Text(feature.eyebrow)
                    .font(.system(size: 8.5, weight: .black))
                    .tracking(2)
                    .foregroundStyle(feature.accent)
                Spacer(minLength: 8)
                Text(heroCount)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }

            Text(heroTitle)
                .font(.system(size: compact ? 23 : 31, weight: .black, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(heroSubtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AtlasTheme.secondaryText)
                .lineLimit(2)

            if !heroStats.isEmpty {
                HStack(spacing: compact ? 11 : 18) {
                    ForEach(heroStats) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.label)
                                .font(.system(size: 7.5, weight: .black))
                                .tracking(0.9)
                                .foregroundStyle(Color.white.opacity(0.38))
                            Text(stat.value)
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(compact ? 13 : 17)
        .frame(maxWidth: compact ? .infinity : 340, alignment: .leading)
        .glass(radius: 23, tint: feature.accent)
    }

    private var controls: some View {
        VStack(spacing: 2) {
            controlButton(map.state.is3D ? "cube.fill" : "cube", active: map.state.is3D) {
                map.send(.toggle3D)
            }
            controlButton("circle.lefthalf.filled") {
                map.send(.cycleStyle)
            }
            if feature == .cameras {
                controlButton("arrow.clockwise") {
                    Task { await tabs.cameras.refresh(force: true) }
                }
            }
            controlButton("scope") {
                focusSelection(selection, force: true)
            }
            Rectangle()
                .fill(AtlasTheme.hairline)
                .frame(width: 24, height: 1)
                .padding(.vertical, 3)
            controlButton("plus") {
                map.send(.zoom(by: 1.6))
            }
            controlButton("minus") {
                map.send(.zoom(by: 1 / 1.6))
            }
        }
        .padding(6)
        .glass(radius: 18, tint: feature.accent)
    }

    private func controlButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.78))
                .background(
                    active ? AnyShapeStyle(feature.accent) : AnyShapeStyle(Color.white.opacity(0.04)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func selectFeature(_ next: AtlasFeature) {
        guard tabs.selected != next.rawValue else { return }
        selection = nil
        // Animated tab changes re-evaluate the map body on every animation tick
        // while MapKit swaps its whole content set. Make the swap one transaction.
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            tabs.selected = next.rawValue
        }
        refreshCards()
    }

    private func select(_ next: AtlasSelection) {
        withAnimation(.snappy(duration: 0.22)) {
            selection = (selection == next) ? nil : next
        }
    }

    // MARK: - Data

    @MainActor
    private func bootstrap() async {
        await tabs.load()
        AtlasPerformance.shared.mark("tabs.ready")
        dataRevision &+= 1
        refreshCards()
        focusActive()
        AtlasPerformance.shared.mark("app.ready")
        if AtlasPerformance.shared.isSamplingEnabled { AtlasPerformance.shared.logSummary() }
    }

    @MainActor
    private func loadRoutes() async {
        AtlasPerformance.shared.begin("routes.prepare")
        var overlays: [WalkOverlay] = []
        var distances: [UUID: Double] = [:]
        for walk in tabs.walks.walks where walk.hasGPSRoute {
            guard let route = try? await tabs.walks.loadRoute(id: walk.id) else { continue }
            let points = route.locations.filter(\.isValidGPXPoint).map { GeoCoordinate($0.coordinate) }
            guard points.count > 1, let bounds = GeoBounds(points: points) else { continue }
            let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let simplified = RouteGeometry.simplify(points, toleranceMeters: 9, maxPoints: 420)
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            overlays.append(WalkOverlay(
                id: walk.id,
                coordinates: coordinates,
                simplified: simplified,
                bounds: bounds
            ))
            distances[walk.id] = RouteGeometry.length(points)
        }
        walkOverlays = overlays
        routeDistances = distances
        dataRevision &+= 1
        refreshCards()
        AtlasPerformance.shared.end("routes.prepare")
        AtlasPerformance.shared.mark("routes.ready")
        AtlasPerformance.shared.increment("routes.loaded", by: Double(overlays.count))
        AtlasPerformance.shared.increment("routes.overview.points", by: Double(overlays.reduce(0) { $0 + $1.simplified.count }))

        if feature == .walks, selection == nil {
            focusActive()
        } else if case .walk(let id)? = selection,
                  let coordinates = overlays.first(where: { $0.id == id })?.coordinates {
            map.focus(on: coordinates.map { GeoCoordinate($0) }, padding: 1.85)
        }
    }

    private func focusActive(animated: Bool = true) {
        let points: [GeoCoordinate]
        switch feature {
        case .walks:
            // The archive is worldwide; open on the most recent route rather
            // than zooming out to a globe of tiny lines.
            points = walkOverlays.first.map { $0.coordinates.map { GeoCoordinate($0) } } ?? []
        case .places:
            // Keep the camera when it already shows places; proximity-sorted
            // cards below then match the map, and we avoid a continent jump and
            // its tile load on every entry.
            let region = map.state.region
            let nearby = tabs.places.places.filter { region.contains(GeoCoordinate($0.coordinate), padding: 0.15) }
            if nearby.count >= 24 { return }
            points = densestPlaceCluster().map { GeoCoordinate($0.coordinate) }
        case .flights:
            // One itinerary at a time keeps the arc legible; continents are not a useful default zoom.
            points = [focusFlight?.originCoordinate, focusFlight?.destinationCoordinate].compactMap { $0 }
        case .parcels:
            points = tabs.parcels.parcels.compactMap { $0.lastLocation.map { GeoCoordinate($0) } }
        case .tfl:
            points = tabs.tfl.stations.map { GeoCoordinate($0.coordinate) }
        case .cameras:
            points = tabs.cameras.cameras.map(\.coordinate)
        }
        guard !points.isEmpty else { return }
        map.focus(
            on: points,
            padding: feature == .walks ? 1.7 : (feature == .cameras ? 1.3 : 1.5),
            verticalBias: feature == .cameras ? -0.04 : -0.14,
            animated: animated
        )
    }

    /// The next flight, or the most recent one when the log is entirely in the past.
    private var focusFlight: Flight? {
        let now = Date()
        if let upcoming = tabs.flights.flights.filter({ $0.departure >= now }).min(by: { $0.departure < $1.departure }) {
            return upcoming
        }
        return tabs.flights.flights.max { $0.departure < $1.departure }
    }

    /// Buckets places on a ~0.35° grid and focuses the busiest city, so a
    /// worldwide archive opens somewhere legible instead of mid-Atlantic.
    private func densestPlaceCluster() -> [Place] {
        let places = tabs.places.places
        guard places.count > 400 else { return places }
        var buckets: [String: [Place]] = [:]
        for place in places {
            let key = "\(Int((place.coordinate.latitude / 0.35).rounded(.down))),\(Int((place.coordinate.longitude / 0.35).rounded(.down)))"
            buckets[key, default: []].append(place)
        }
        return buckets.max { $0.value.count < $1.value.count }?.value ?? places
    }

    private func focusSelection(_ selection: AtlasSelection?, force: Bool = false) {
        guard let selection else {
            focusActive(animated: false)
            return
        }

        let points: [GeoCoordinate]
        var snap = false
        switch selection {
        case .walk(let id):
            points = (walkOverlays.first(where: { $0.id == id })?.coordinates ?? []).map { GeoCoordinate($0) }
        case .place(let id):
            points = tabs.places.places.first { $0.id == id }.map { [GeoCoordinate($0.coordinate)] } ?? []
        case .flight(let id):
            let flight = tabs.flights.flights.first { $0.id == id }
            points = [flight?.originCoordinate, flight?.destinationCoordinate].compactMap { $0 }
        case .parcel(let id):
            points = tabs.parcels.parcels.first { $0.id == id }?.lastLocation.map { [GeoCoordinate($0)] } ?? []
        case .station(let id):
            points = tabs.tfl.stations.first { $0.id == id }.map { [GeoCoordinate($0.coordinate)] } ?? []
        case .camera(let id):
            // Selecting a camera must stay instant. Locating is explicit:
            // the scope control and the monitor's locate button pass `force`.
            guard force else { return }
            snap = true
            points = tabs.cameras.cameras.first { $0.id == id }.map { [$0.coordinate] } ?? []
        }

        guard !points.isEmpty else { return }
        map.focus(on: points, padding: 2.1, animated: !snap)
    }

    private func routeDistance(for id: UUID) -> Double? { routeDistances[id] }

    private func walkTitle(_ walk: WalkRouteSummary) -> String {
        if let title = walk.title, !title.isEmpty { return title }
        return timeOfDayTitle(walk.startDate, activity: Self.activityNoun(walk.activity))
    }

    private static func activityNoun(_ activity: String?) -> String {
        switch activity?.lowercased() {
        case "walking", "walk": return "walk"
        case "hiking", "hike": return "hike"
        case "running", "run": return "run"
        case "cycling", "bike", "biking": return "ride"
        default: return "walk"
        }
    }

    private var selectedCamera: JamCam? {
        guard case .camera(let id)? = selection else { return nil }
        return tabs.cameras.cameras.first { $0.id == id }
    }

    private var emptyListText: String {
        switch feature {
        case .parcels:
            return "No parcels are being tracked."
        case .places:
            return tabs.places.places.isEmpty
                ? "No saved places yet. Search Apple Maps above to add one."
                : "No saved places match."
        case .cameras:
            if tabs.cameras.isLoading { return "Loading live TfL cameras…" }
            if let error = tabs.cameras.errorMessage { return error }
            return "No live cameras available."
        default:
            return "Nothing here yet."
        }
    }

    // MARK: - Hero copy

    private var heroCount: String {
        switch feature {
        case .walks: return "\(tabs.walks.walks.count) WALKS"
        case .places: return "\(tabs.places.places.count) SAVED"
        case .flights: return "\(tabs.flights.flights.count) FLIGHTS"
        case .parcels: return "\(tabs.parcels.parcels.count) PARCELS"
        case .tfl: return "\(tabs.tfl.stations.count) STATIONS"
        case .cameras: return tabs.cameras.isLoading ? "CONNECTING" : "\(tabs.cameras.onlineCount) LIVE"
        }
    }

    private var heroTitle: String {
        guard let selection else { return feature.title }
        switch selection {
        case .walk(let id):
            guard let walk = tabs.walks.walks.first(where: { $0.id == id }) else { return "Walk" }
            return walkTitle(walk)
        case .place(let id):
            return tabs.places.places.first { $0.id == id }?.name ?? "Place"
        case .flight(let id):
            guard let flight = tabs.flights.flights.first(where: { $0.id == id }) else { return "Flight" }
            return "\(flight.origin) → \(flight.destination)"
        case .parcel(let id):
            return tabs.parcels.parcels.first { $0.id == id }?.carrier ?? "Parcel"
        case .station(let id):
            return tabs.tfl.stations.first { $0.id == id }?.name ?? "Station"
        case .camera(let id):
            return tabs.cameras.cameras.first { $0.id == id }?.name ?? "Camera"
        }
    }

    private var heroSubtitle: String {
        guard let selection else { return feature.blurb }
        switch selection {
        case .walk(let id):
            guard let walk = tabs.walks.walks.first(where: { $0.id == id }) else { return "" }
            return "\(walk.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(walk.startDate.formatted(date: .omitted, time: .shortened))"
        case .place(let id):
            guard let place = tabs.places.places.first(where: { $0.id == id }) else { return "" }
            return place.note.isEmpty ? "Saved coordinate" : place.note
        case .flight(let id):
            guard let flight = tabs.flights.flights.first(where: { $0.id == id }) else { return "" }
            return "\(flight.number) · departs \(flight.departure.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
        case .parcel(let id):
            guard let parcel = tabs.parcels.parcels.first(where: { $0.id == id }) else { return "" }
            return "\(parcel.status) · \(parcel.trackingNumber)"
        case .station(let id):
            guard let station = tabs.tfl.stations.first(where: { $0.id == id }) else { return "" }
            return station.lines.joined(separator: " · ")
        case .camera(let id):
            guard let camera = tabs.cameras.cameras.first(where: { $0.id == id }) else { return "" }
            let state = camera.isAvailable ? "Live" : "Offline"
            return camera.view.isEmpty ? "TfL traffic camera · \(state)" : "\(camera.view) · \(state)"
        }
    }

    private var heroStats: [HeroStat] {
        if let selection {
            switch selection {
            case .walk(let id):
                guard let walk = tabs.walks.walks.first(where: { $0.id == id }) else { return [] }
                return [
                    HeroStat(id: "distance", label: "DISTANCE",
                             value: routeDistance(for: id).map { String(format: "%.1f km", $0 / 1_000) } ?? "—"),
                    HeroStat(id: "duration", label: "DURATION", value: "\(Int(walk.durationSeconds / 60)) min"),
                    HeroStat(id: "points", label: "POINTS", value: "\(walkOverlays.first { $0.id == id }?.coordinates.count ?? 0)"),
                ]
            case .place(let id):
                guard let place = tabs.places.places.first(where: { $0.id == id }) else { return [] }
                return [
                    HeroStat(id: "lat", label: "LAT", value: String(format: "%.4f", place.coordinate.latitude)),
                    HeroStat(id: "lon", label: "LON", value: String(format: "%.4f", place.coordinate.longitude)),
                    HeroStat(id: "saved", label: "SAVED",
                             value: place.createdAt.formatted(.dateTime.day().month(.abbreviated))),
                ]
            case .flight(let id):
                guard let flight = tabs.flights.flights.first(where: { $0.id == id }) else { return [] }
                let hours = Int(flight.durationSeconds / 3_600)
                let minutes = Int(flight.durationSeconds.truncatingRemainder(dividingBy: 3_600) / 60)
                return [
                    HeroStat(id: "departs", label: "DEPARTS",
                             value: flight.departure.formatted(.dateTime.day().month(.abbreviated))),
                    HeroStat(id: "arrives", label: "ARRIVES",
                             value: flight.arrival.formatted(.dateTime.day().month(.abbreviated))),
                    HeroStat(id: "duration", label: "DURATION", value: "\(hours)h \(minutes)m"),
                ]
            case .parcel(let id):
                guard let parcel = tabs.parcels.parcels.first(where: { $0.id == id }) else { return [] }
                return [
                    HeroStat(id: "status", label: "STATUS", value: parcel.status),
                    HeroStat(id: "carrier", label: "CARRIER", value: parcel.carrier),
                    HeroStat(id: "updated", label: "UPDATED",
                             value: parcel.updatedAt.formatted(.relative(presentation: .named))),
                ]
            case .station(let id):
                guard let station = tabs.tfl.stations.first(where: { $0.id == id }) else { return [] }
                return [
                    HeroStat(id: "lines", label: "LINES", value: "\(station.lines.count)"),
                    HeroStat(id: "lat", label: "LAT", value: String(format: "%.4f", station.coordinate.latitude)),
                    HeroStat(id: "lon", label: "LON", value: String(format: "%.4f", station.coordinate.longitude)),
                ]
            case .camera(let id):
                guard let camera = tabs.cameras.cameras.first(where: { $0.id == id }) else { return [] }
                return [
                    HeroStat(id: "feed", label: "FEED", value: camera.isAvailable ? "LIVE" : "OFFLINE"),
                    HeroStat(id: "view", label: "VIEW", value: String(camera.view.prefix(14))),
                    HeroStat(id: "updated", label: "UPDATED",
                             value: tabs.cameras.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—"),
                ]
            }
        }

        switch feature {
        case .walks:
            return [
                HeroStat(id: "total", label: "TOTAL", value: "\(tabs.walks.walks.count)"),
                HeroStat(id: "gps", label: "GPS", value: "\(tabs.walks.walks.filter(\.hasGPSRoute).count)"),
                HeroStat(id: "months", label: "MONTHS", value: "\(tabs.walks.months.count)"),
            ]
        case .places:
            return [
                HeroStat(id: "saved", label: "SAVED", value: "\(tabs.places.places.count)"),
                HeroStat(id: "latest", label: "LATEST",
                         value: tabs.places.places.map(\.createdAt).max()?.formatted(.dateTime.day().month(.abbreviated)) ?? "—"),
            ]
        case .flights:
            return [
                HeroStat(id: "flights", label: "FLIGHTS", value: "\(tabs.flights.flights.count)"),
                HeroStat(id: "airports", label: "AIRPORTS",
                         value: "\(Set(tabs.flights.flights.flatMap { [$0.origin, $0.destination] }).count)"),
            ]
        case .parcels:
            return [
                HeroStat(id: "parcels", label: "TRACKING", value: "\(tabs.parcels.parcels.count)"),
                HeroStat(id: "moving", label: "MOVING",
                         value: "\(tabs.parcels.parcels.filter { $0.status.lowercased().contains("transit") || $0.status.lowercased().contains("delivery") }.count)"),
            ]
        case .tfl:
            return [
                HeroStat(id: "stations", label: "STATIONS", value: "\(tabs.tfl.stations.count)"),
                HeroStat(id: "lines", label: "LINES",
                         value: "\(Set(tabs.tfl.stations.flatMap(\.lines)).count)"),
            ]
        case .cameras:
            return [
                HeroStat(id: "cameras", label: "CAMERAS", value: "\(tabs.cameras.cameras.count)"),
                HeroStat(id: "online", label: "ONLINE", value: "\(tabs.cameras.onlineCount)"),
                HeroStat(id: "updated", label: "UPDATED",
                         value: tabs.cameras.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—"),
            ]
        }
    }

    // MARK: - Cards

    /// Search filters the active section only: the sidebar is a lens over the
    /// current archive, not a global command palette.
    private var visibleCards: [AtlasCard] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cachedCards }
        return cachedCards.filter { card in
            card.title.localizedCaseInsensitiveContains(query)
                || card.subtitle.localizedCaseInsensitiveContains(query)
                || card.badge.localizedCaseInsensitiveContains(query)
        }
    }

    private var footerStatus: String {
        switch feature {
        case .cameras:
            let updated = tabs.cameras.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—"
            return "\(tabs.cameras.onlineCount) online · updated \(updated)"
        default:
            return "\(heroCount) · synced locally"
        }
    }

    /// Cards are rebuilt only when the data or the active feature changes, not
    /// on every camera tick. 1,550 formatted strings in `body` was measurable.
    private var cardsKey: String {
        let placeCamera: String
        if feature == .places {
            let center = map.state.region.center
            placeCamera = "|\(Int(center.latitude * 40)),\(Int(center.longitude * 40))"
        } else {
            placeCamera = ""
        }
        return "\(feature.rawValue)|\(dataRevision)|\(tabs.walks.walks.count)|\(routeDistances.count)|\(tabs.places.places.count)|\(tabs.flights.flights.count)|\(tabs.parcels.parcels.count)|\(tabs.tfl.stations.count)|\(tabs.cameras.cameras.count)|\(tabs.cameras.lastUpdated?.timeIntervalSince1970 ?? 0)|\(tabs.places.places.first?.id.uuidString ?? "-")\(placeCamera)"
    }

    @MainActor
    private func refreshCards() {
        let key = cardsKey
        guard key != cachedCardsKey || cachedCards.isEmpty else { return }
        let started = AtlasPerformance.shared.isSamplingEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let built = buildCards()
        cachedCards = built
        cachedCardsKey = key
        if started > 0 {
            AtlasPerformance.shared.record(
                "ui.cards.build",
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            )
            AtlasPerformance.shared.increment("ui.cards.items", by: Double(built.count))
            AtlasPerformance.shared.increment("ui.cards.rebuilds")
        }
    }

    private func buildCards() -> [AtlasCard] {
        switch feature {
        case .walks:
            return tabs.walks.walks.map { walk in
                AtlasCard(
                    id: "walk-\(walk.id)",
                    selection: .walk(walk.id),
                    title: walkTitle(walk),
                    subtitle: "\(walk.startDate.formatted(date: .omitted, time: .shortened)) · \(walk.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))",
                    badge: walk.hasGPSRoute ? "GPS route" : "No GPS",
                    icon: "figure.walk",
                    metric: routeDistance(for: walk.id).map { String(format: "%.1f km", $0 / 1_000) }
                        ?? "\(Int(walk.durationSeconds / 60)) min"
                )
            }

        case .places:
            let center = map.state.region.center
            let cosLatitude = cos(center.latitude * .pi / 180)
            let ordered = tabs.places.places.sorted { lhs, rhs in
                let lhsLat = lhs.coordinate.latitude - center.latitude
                let lhsLon = (lhs.coordinate.longitude - center.longitude) * cosLatitude
                let rhsLat = rhs.coordinate.latitude - center.latitude
                let rhsLon = (rhs.coordinate.longitude - center.longitude) * cosLatitude
                return lhsLat * lhsLat + lhsLon * lhsLon < rhsLat * rhsLat + rhsLon * rhsLon
            }
            return ordered.map { place in
                AtlasCard(
                    id: "place-\(place.id)",
                    selection: .place(place.id),
                    title: place.name,
                    subtitle: place.note.isEmpty ? "Saved place" : place.note,
                    badge: "Saved",
                    icon: "mappin.and.ellipse",
                    metric: String(format: "%.3f, %.3f", place.coordinate.latitude, place.coordinate.longitude)
                )
            }

        case .flights:
            return tabs.flights.flights.map { flight in
                let hours = Int(flight.durationSeconds / 3_600)
                let minutes = Int(flight.durationSeconds.truncatingRemainder(dividingBy: 3_600) / 60)
                return AtlasCard(
                    id: "flight-\(flight.id)",
                    selection: .flight(flight.id),
                    title: "\(flight.origin) → \(flight.destination)",
                    subtitle: "\(flight.number) · \(flight.departure.formatted(.dateTime.day().month(.abbreviated).hour().minute()))",
                    badge: flight.departure >= Date() ? "Upcoming" : "Past",
                    icon: "airplane",
                    metric: "\(hours)h \(minutes)m"
                )
            }

        case .parcels:
            return tabs.parcels.parcels.map { parcel in
                AtlasCard(
                    id: "parcel-\(parcel.id)",
                    selection: .parcel(parcel.id),
                    title: "\(parcel.carrier) parcel",
                    subtitle: parcel.trackingNumber,
                    badge: parcel.status,
                    icon: "shippingbox.fill",
                    metric: parcel.updatedAt.formatted(.relative(presentation: .named))
                )
            }

        case .tfl:
            return tabs.tfl.stations.map { station in
                AtlasCard(
                    id: "station-\(station.id)",
                    selection: .station(station.id),
                    title: station.name,
                    subtitle: station.lines.prefix(3).joined(separator: " · "),
                    badge: station.lines.first ?? "Station",
                    icon: "tram.fill",
                    metric: station.lines.count > 1 ? "+\(station.lines.count - 1) lines" : "1 line"
                )
            }

        case .cameras:
            // Stable network centre: panning the map never reorders the list.
            let center = tabs.cameras.coverageCenter
            let cosLatitude = cos(center.latitude * .pi / 180)
            let ordered = tabs.cameras.cameras.sorted { lhs, rhs in
                let lhsLat = lhs.coordinate.latitude - center.latitude
                let lhsLon = (lhs.coordinate.longitude - center.longitude) * cosLatitude
                let rhsLat = rhs.coordinate.latitude - center.latitude
                let rhsLon = (rhs.coordinate.longitude - center.longitude) * cosLatitude
                return lhsLat * lhsLat + lhsLon * lhsLon < rhsLat * rhsLat + rhsLon * rhsLon
            }
            // Every camera, nearest first. The list is lazy, so 889 rows cost
            // nothing until they scroll into view — and search covers the whole
            // network instead of a nearby subset.
            return ordered.map { camera in
                let meters = camera.coordinate.distance(to: center)
                return AtlasCard(
                    id: "camera-\(camera.id)",
                    selection: .camera(camera.id),
                    title: camera.name,
                    subtitle: camera.view.isEmpty ? "TfL traffic camera" : camera.view,
                    badge: camera.isAvailable ? "Live" : "Offline",
                    icon: "video.fill",
                    metric: meters < 1_000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1_000)
                )
            }
        }
    }

    // MARK: - Reflex (debug only)

    private func startReflexServer() {
        #if DEBUG
        let enabled = true
        #else
        let enabled = ProcessInfo.processInfo.environment["ATLAS_REFLEX"] == "1"
        #endif
        guard enabled, reflexServer == nil else { return }
        let tree = makeAtlasTree(tabs: tabs)
        let server = ReflexServer(tree: tree, port: 18765, extraHandler: { command in
            let parts = command.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard let verb = parts.first?.lowercased() else { return nil }
            switch verb {
            case "tab":
                let index = parts.count > 1 ? Int(parts[1]) : nil
                if let index {
                    await MainActor.run { tabs.selected = min(max(index, 0), AtlasFeature.allCases.count - 1) }
                    return "{\"tab\":\(min(max(index, 0), AtlasFeature.allCases.count - 1))}"
                }
                return await MainActor.run { "{\"tab\":\(tabs.selected)}" }
            case "map":
                return await MainActor.run { tabs.map.introspectionNode.jsonString() }
            case "camera":
                let requested = parts.count > 1
                    ? parts.dropFirst().joined(separator: " ")
                    : "first"
                return await MainActor.run {
                    if requested.lowercased() == "clear" {
                        selection = nil
                        return "{\"camera\":null}"
                    }
                    if requested.lowercased() == "locate" {
                        focusSelection(selection, force: true)
                        return "{\"camera\":\"located\"}"
                    }
                    if requested.lowercased() == "status" {
                        if case .camera(let id) = selection {
                            return "{\"selected\":\"\(id)\"}"
                        }
                        return "{\"selected\":null}"
                    }
                    if requested.lowercased() == "dots" {
                        let dots = tabs.cameras.dots(in: map.state.region)
                        let list = dots
                            .map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }
                            .joined(separator: ",")
                        return "{\"span\":\(map.state.region.latitudeDelta),\"dots\":[\(list)]}"
                    }
                    let camera: JamCam?
                    if requested.lowercased() == "first" {
                        camera = tabs.cameras.cameras.first(where: \.isAvailable) ?? tabs.cameras.cameras.first
                    } else {
                        camera = tabs.cameras.cameras.first {
                            $0.id == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame
                        }
                    }
                    guard let camera else { return "{\"error\":\"camera not loaded\"}" }
                    selection = .camera(camera.id)
                    return "{\"camera\":\"\(camera.id)\"}"
                }
            case "search":
                let query = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
                return await MainActor.run {
                    searchText = query
                    return "{\"search\":\"\(query)\",\"results\":\(visibleCards.count)}"
                }
            case "places":
                let requested = parts.count > 1
                    ? parts.dropFirst().joined(separator: " ")
                    : "list"
                let verb = String(requested.prefix(while: { !$0.isWhitespace })).lowercased()
                let argument = String(requested.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                switch verb {
                case "search":
                    await MainActor.run { placeQuery = argument }
                    await runPlaceSearch()
                    let results = await MainActor.run { tabs.places.results }
                    let list = results.enumerated().map { index, result in
                        "{\"index\":\(index),\"name\":\"\(result.name)\",\"address\":\"\(result.address)\",\"lat\":\(result.latitude),\"lon\":\(result.longitude)}"
                    }.joined(separator: ",")
                    return "{\"results\":[\(list)]}"
                case "save":
                    guard let index = Int(argument) else { return "{\"error\":\"usage: places save <index>\"}" }
                    guard let place = await tabs.places.save(resultAt: index) else {
                        return "{\"error\":\"no result at index \(index)\"}"
                    }
                    return "{\"saved\":\"\(place.name)\",\"id\":\"\(place.id.uuidString)\"}"
                case "clear":
                    await MainActor.run {
                        placeQuery = ""
                        tabs.places.clearResults()
                    }
                    return "{\"results\":[]}"
                default:
                    let places = await MainActor.run { tabs.places.places }
                    let filtered = argument.isEmpty
                        ? places
                        : places.filter { $0.name.localizedCaseInsensitiveContains(argument) }
                    let list = filtered.prefix(50).map { place in
                        "{\"name\":\"\(place.name)\",\"lat\":\(place.coordinate.latitude),\"lon\":\(place.coordinate.longitude)}"
                    }.joined(separator: ",")
                    return "{\"places\":[\(list)],\"count\":\(places.count),\"matched\":\(filtered.count)}"
                }
            case "sidebar":
                let action = parts.count > 1 ? String(parts[1]).lowercased() : "toggle"
                return await MainActor.run {
                    switch action {
                    case "open": sidebarOpen = true
                    case "close": sidebarOpen = false
                    case "collapse": sidebarCollapsed = true
                    case "expand": sidebarCollapsed = false
                    default: sidebarOpen.toggle()
                    }
                    return "{\"sidebar\":\(sidebarOpen),\"collapsed\":\(sidebarCollapsed)}"
                }
            case "perf":
                let sub = parts.count > 1 ? String(parts[1]).lowercased() : "report"
                return await MainActor.run {
                    switch sub {
                    case "reset":
                        AtlasPerformance.shared.reset()
                        return "{\"ok\":true}"
                    case "frames":
                        let action = parts.count > 2 ? String(parts[2]).lowercased() : "status"
                        if action == "start" {
                            FrameProbe.shared.start()
                            return "{\"frames\":\"recording\"}"
                        }
                        if action == "stop" { return FrameProbe.shared.stop().jsonString() }
                        return FrameProbe.shared.statsJSON()
                    default:
                        return AtlasPerformance.shared.reportJSON()
                    }
                }
            default:
                return nil
            }
        })
        server.start()
        reflexServer = server
    }
}

// MARK: - Row

/// One line per item: icon, title, subtitle, and a trailing metric/badge.
/// The sidebar shows ~14 of these at once instead of four horizontal cards.
struct AtlasRowView: View {
    let card: AtlasCard
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(isSelected ? 0.24 : 0.11))
                    Image(systemName: card.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(card.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AtlasTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 1.5) {
                    Text(card.metric)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(card.badge.uppercased())
                        .font(.system(size: 7, weight: .black))
                        .tracking(0.5)
                        .foregroundStyle(accent.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.14)
                          : Color.white.opacity(hovered ? 0.05 : 0.0001))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Copy helpers

private func timeOfDayTitle(_ date: Date, activity: String = "walk") -> String {
    let noun = activity.lowercased()
    let hour = Calendar.current.component(.hour, from: date)
    switch hour {
    case 5..<12: return "Morning \(noun)"
    case 12..<17: return "Afternoon \(noun)"
    case 17..<22: return "Evening \(noun)"
    default: return "Night \(noun)"
    }
}

private extension View {
    /// `textInputAutocapitalization` is iOS-only; the Mac has no equivalent.
    @ViewBuilder
    func noAutoCapitalisation() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
