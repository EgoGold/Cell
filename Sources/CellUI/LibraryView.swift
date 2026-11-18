import SwiftUI
import CellCore

struct LibraryView: View {
    @Bindable var model: AppModel
    let title: String
    let apps: [AppEntry]

    var body: some View {
        NavigationStack(path: $model.libraryPath) {
            Group {
                if !model.hasEngine && model.apps.isEmpty {
                    OnboardingView(model: model)
                } else if apps.isEmpty {
                    EmptyStateView(title: model.searchText.isEmpty ? "No apps yet" : "No matches",
                                   systemImage: "square.grid.2x2",
                                   message: model.searchText.isEmpty
                                    ? "Drag a Windows program or installer here, or install Steam."
                                    : "Nothing matches “\(model.searchText)”.",
                                   actionTitle: model.searchText.isEmpty ? "Add Program…" : nil,
                                   action: model.searchText.isEmpty ? { addProgram() } : nil)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.spacing) {
                            HomeBanners(model: model)
                            RunningStrip(model: model)
                            HomeGrid(model: model, apps: apps)
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: UUID.self) { id in
                if let app = model.app(id) {
                    AppDetailView(model: model, appID: app.id)
                } else {
                    EmptyStateView(title: "App not found", systemImage: "questionmark.app", message: "It was removed from the library.")
                }
            }
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search apps")
            .sheet(item: $model.renaming) { app in RenameSheet(model: model, app: app) }
            .toolbar { LibraryToolbar(model: model, addProgram: addProgram) }
        }
    }

    private func addProgram() {
        let urls = Panels.chooseFiles(title: "Choose a Windows program or installer",
                                      extensions: ["exe", "msi", "lnk"], multiple: true)
        model.open(urls)
    }
}

/// Home's cards. Click one to open it; drag one onto another place to put it there (the others make room while
/// you drag). Done with a plain drag gesture: the system's drag and drop never starts on a card that is also
/// a button, which is why dragging did nothing before.
///
/// The card being dragged is drawn above the grid, exactly under the pointer; its own place in the grid stays
/// empty. (It used to be the grid's card moved by an offset from its place: when the others made room, its place
/// moved before the offset knew it, and the card jumped a whole card to the side and back.) The place it goes to
/// is worked out from the grid's fixed places, so the same pointer position always gives the same order.
struct HomeGrid: View {
    let model: AppModel
    let apps: [AppEntry]

    private let columns = [GridItem(.adaptive(minimum: Theme.cardWidth, maximum: Theme.cardWidth + 40), spacing: 20)]
    private static let space = "homeGrid"

    /// Where each card sits. Kept outside the view's state: storing it there redrew the grid every time a card
    /// reported its place, which reported the places again (dragging stuttered and the page never came to rest).
    @State private var places = CardPlaces()
    @State private var scrolling = HomeDragScroll()
    @State private var dragged: UUID?
    /// Where inside the card it was grabbed.
    @State private var grab: CGSize = .zero
    /// The dragged card's top left corner.
    @State private var floating: CGPoint = .zero
    @State private var cardSize: CGSize = .zero
    /// The grid's places, measured when the drag began.
    @State private var grid: GridPlaces?
    /// The order while a card is being dragged (saved when it is dropped).
    @State private var liveOrder: [UUID]?
    /// The dropped card is gliding into its place.
    @State private var landing = false
    /// True while SwiftUI runs a drag. It goes back by itself when a drag ends in any way, also when SwiftUI
    /// cancels it without telling `onEnded` (the card then stayed in mid-air and the grid frozen).
    @GestureState private var dragging = false

    private var arranged: [AppEntry] {
        guard let liveOrder else { return apps }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return liveOrder.compactMap { byID[$0] }
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(arranged) { app in
                AppCard(model: model, app: app)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CardFrames.self, value: [app.id: proxy.frame(in: .named(Self.space))])
                    })
                    .opacity(dragged == app.id ? 0 : 1)
                    .onTapGesture { model.libraryPath.append(app.id) }
                    .gesture(drag(app.id), isEnabled: model.searchText.isEmpty)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .coordinateSpace(name: Self.space)
        .background(HomeDragScrollAnchor(scrolling: scrolling))
        .overlay(alignment: .topLeading) {
            if let id = dragged, let app = apps.first(where: { $0.id == id }) {
                AppCard(model: model, app: app, lifted: true)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .offset(x: floating.x, y: floating.y)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(CardFrames.self) { places.frames = $0 }
        .onChange(of: dragging) { _, active in
            if !active, dragged != nil { finishDrag() }
        }
        .onDisappear { scrolling.stop() }
    }

    private func drag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !landing else { return }
                if dragged == nil {
                    let order = apps.map(\.id)
                    guard let frame = places.frames[id], let measured = GridPlaces(frames: places.frames, order: order) else { return }
                    grid = measured
                    cardSize = frame.size
                    grab = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
                    liveOrder = order
                    dragged = id
                }
                guard dragged == id else { return }
                moveDrag(to: value.location)
                scrolling.track(value.location) { moveDrag(to: $0) }
            }
            .onEnded { _ in finishDrag() }
    }

    private func moveDrag(to point: CGPoint) {
        guard let id = dragged, !landing else { return }
        floating = CGPoint(x: point.x - grab.width, y: point.y - grab.height)
        let middle = CGPoint(x: floating.x + cardSize.width / 2, y: floating.y + cardSize.height / 2)
        guard let current = liveOrder, let index = grid?.index(at: middle, count: current.count) else { return }
        let moved = HomeGrid.placing(id, at: index, in: current)
        if moved != current {
            model.homeDragMoves += 1
            withAnimation(.snappy(duration: 0.22)) { liveOrder = moved }
        }
    }

    /// Saves the new order, then the card glides into its place and is put down.
    private func finishDrag() {
        scrolling.stop()
        guard let id = dragged, !landing else { return }
        let order = liveOrder ?? apps.map(\.id)
        if order != apps.map(\.id) { model.setHomeOrder(order) }
        guard let index = order.firstIndex(of: id), let place = grid?.rect(at: index) else {
            putDown()
            return
        }
        landing = true
        withAnimation(.snappy(duration: 0.22)) {
            floating = place.origin
        } completion: {
            putDown()
        }
    }

    private func putDown() {
        dragged = nil
        liveOrder = nil
        grid = nil
        landing = false
    }

    /// The order after putting `id` at `index` (the cards between shift over). The same index always gives the
    /// same order, so small pointer movements can't swap cards back and forth.
    static func placing(_ id: UUID, at index: Int, in order: [UUID]) -> [UUID] {
        guard let from = order.firstIndex(of: id) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(id, at: min(max(index, 0), result.count))
        return result
    }

    /// The order after dropping `id` on `target`: it takes the target's place and the cards between shift over.
    static func moving(_ id: UUID, onto target: UUID, in order: [UUID]) -> [UUID] {
        guard id != target, let to = order.firstIndex(of: target) else { return order }
        return placing(id, at: to, in: order)
    }
}

/// Card positions, updated without redrawing anything.
private final class CardPlaces {
    var frames: [UUID: CGRect] = [:]
}

/// The grid's places (index → rectangle): columns at fixed x positions, rows a fixed distance apart. Measured from
/// the cards on screen when a drag begins; they don't move while cards change places.
struct GridPlaces: Equatable {
    var columns: [CGFloat]
    var firstRowY: CGFloat
    var rowPitch: CGFloat
    var size: CGSize

    init?(frames: [UUID: CGRect], order: [UUID]) {
        let known = order.enumerated().compactMap { index, id in frames[id].map { (index, $0) } }
        guard let first = known.first else { return nil }
        var xs: [CGFloat] = []
        for (_, rect) in known where !xs.contains(where: { abs($0 - rect.minX) < 1 }) { xs.append(rect.minX) }
        columns = xs.sorted()
        size = first.1.size
        let perRow = columns.count
        let firstRow = first.0 / perRow
        // Two cards in different rows give the distance between rows; otherwise a card's height and the spacing.
        if let other = known.first(where: { $0.0 / perRow != firstRow }) {
            rowPitch = (other.1.minY - first.1.minY) / CGFloat(other.0 / perRow - firstRow)
        } else {
            rowPitch = size.height + 24
        }
        firstRowY = first.1.minY - CGFloat(firstRow) * rowPitch
    }

    func rect(at index: Int) -> CGRect? {
        guard !columns.isEmpty, index >= 0 else { return nil }
        return CGRect(x: columns[index % columns.count], y: firstRowY + CGFloat(index / columns.count) * rowPitch,
                      width: size.width, height: size.height)
    }

    /// The index of the place that contains `point`, if any (the gaps between cards belong to none).
    func index(at point: CGPoint, count: Int) -> Int? {
        guard let column = columns.lastIndex(where: { $0 <= point.x }), point.x <= columns[column] + size.width,
              rowPitch > 0, point.y >= firstRowY else { return nil }
        let row = Int((point.y - firstRowY) / rowPitch)
        guard point.y <= firstRowY + CGFloat(row) * rowPitch + size.height else { return nil }
        let index = row * columns.count + column
        return index < count ? index : nil
    }
}

private struct CardFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct LibraryToolbar: ToolbarContent {
    let model: AppModel
    let addProgram: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Program or Installer…", systemImage: "plus.app", action: addProgram)
                Button("Add App Folder…", systemImage: "folder.badge.plus") {
                    model.open(Panels.chooseFiles(title: "Choose the folder of a Windows app or game", allowFolders: true, allowFiles: false, multiple: true))
                }
                if let container = model.defaultContainer {
                    if SteamIntegration.isInstalled(in: container) {
                        Button("Look for New Steam Games", systemImage: "arrow.clockwise") { model.rescan(container) }
                    } else {
                        Button("Install Steam", systemImage: "gamecontroller") { model.installSteam(in: container) }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add apps and games")
        }
    }
}

struct AppCard: View {
    let model: AppModel
    let app: AppEntry
    /// Being dragged on Home: it keeps its raised look the whole time (losing the hover look when the drag
    /// began made the card flash).
    var lifted = false
    @State private var isHovering = false

    var body: some View {
        let raised = isHovering || lifted
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AppArtworkView(app: app)
                    .frame(width: Theme.cardWidth, height: Theme.cardArtHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(lifted ? 0.45 : (raised ? 0.35 : 0.18)), radius: raised ? 14 : 6, y: raised ? 8 : 3)
                if raised || model.isRunning(app) || model.launchStatus[app.id] != nil {
                    PlayButton(model: model, app: app, compact: true).padding(10)
                }
            }
            .scaleEffect(raised ? 1.02 : 1)
            .animation(.snappy(duration: 0.18), value: raised)

            HStack(spacing: 6) {
                if app.artworkURL != nil { AppIconView(app: app, size: 18) }
                Text(app.name).font(.headline).lineLimit(1)
            }
            Group {
                if let status = model.launchStatus[app.id] {
                    Text(status).foregroundStyle(Color.accentColor)
                } else if model.isRunning(app) {
                    Text("Running").foregroundStyle(.green)
                } else {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .frame(width: Theme.cardWidth)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { AppContextMenu(model: model, app: app) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let container = model.container(app.containerID), model.visibleContainers.count > 1 { parts.append(container.name) }
        if let backend = app.learned.workingBackend ?? model.decision(for: app)?.backend {
            parts.append(backend.displayName)
        }
        return parts.joined(separator: " · ")
    }
}

struct PlayButton: View {
    let model: AppModel
    let app: AppEntry
    var compact = false

    var body: some View {
        if model.isRunning(app) {
            Button {
                model.stop(app)
            } label: {
                Label(model.isStopping(app) ? "Force Quit" : "Stop", systemImage: model.isStopping(app) ? "xmark.octagon.fill" : "stop.fill")
                    .labelStyle(.iconOnly).frame(width: compact ? 18 : nil)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(compact ? .regular : .large)
            .help(model.isStopping(app) ? "Force quit \(app.name) now" : "Quit \(app.name)")
        } else if model.launchStatus[app.id] != nil {
            ProgressView().controlSize(.small).padding(8).background(.regularMaterial, in: Circle())
        } else {
            Button {
                model.launch(app)
            } label: {
                if compact {
                    Image(systemName: "play.fill").frame(width: 18)
                } else {
                    Label("Play", systemImage: "play.fill").frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent).controlSize(compact ? .regular : .large)
            .help("Start \(app.name)")
        }
    }
}

/// Right-click menu of an app: play, where it lives, the Applications folder, Home, uninstalling.
/// (Steam's own features stay in Steam; for Steam games Cell only offers uninstalling.)
struct AppContextMenu: View {
    let model: AppModel
    let app: AppEntry

    var body: some View {
        if model.isRunning(app) {
            Button(model.quitTitle(for: app)) { model.stop(app) }
        } else {
            Button("Play") { model.launch(app) }
        }
        Divider()
        Button("Rename…") { model.renaming = app }
        Button("Go to Container") { model.goToContainer(of: app) }
        if app.shortcutPath == nil {
            Button("Add to Applications Folder") { model.addToApplications(app) }
        } else {
            Button("Remove from Applications Folder") { model.removeFromApplications(app) }
        }
        if app.isHidden {
            Button("Show on Home") { model.showOnHome(app) }
        } else {
            Button("Remove from Home") { model.removeFromHome(app) }
        }
        Divider()
        Button("Uninstall…", role: .destructive) { model.pendingUninstall = app }
    }
}

/// Things worth knowing before playing: no engine can draw games yet, engines being checked.
struct HomeBanners: View {
    let model: AppModel

    var body: some View {
        if model.canRunDirect3D11Games == false { NoDirect3D11Warning(model: model) }
        if let status = model.engineCheckStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// What runs right now, with a quick way to quit it.
struct RunningStrip: View {
    let model: AppModel

    var body: some View {
        let running = model.apps.filter { model.isRunning($0) }
        if !running.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Label("Running now", systemImage: "play.circle.fill").font(.headline).foregroundStyle(.green)
                    ForEach(running) { app in
                        HStack(spacing: 8) {
                            AppIconView(app: app, size: 22)
                            Text(app.name).lineLimit(1)
                            Button(model.quitTitle(for: app)) { model.stop(app) }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                }
            }
        }
    }
}

/// First run: nothing installed yet. One button does everything.
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wand.and.stars").font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentColor)
            Text("Welcome to Cell").font(.largeTitle.weight(.bold))
            Text("Play Windows games and run Windows apps on your Mac. Cell downloads and sets up everything it needs, then picks the right engine for every game automatically.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Button {
                model.selection = .setup
                model.runSetup()
            } label: {
                Label("Set Up Everything", systemImage: "wand.and.stars").frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            if !model.bottles.isEmpty {
                Text("Found \(model.bottles.count) bottle\(model.bottles.count == 1 ? "" : "s") from Porting Kit, CrossOver or Whisky — your games come along automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renames an app (Home, Dock and its Applications shortcut use the new name).
struct RenameSheet: View {
    let model: AppModel
    let app: AppEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(app.name)”").font(.title3.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: done).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = app.name }
    }

    private func done() {
        model.rename(app, to: name)
        dismiss()
    }
}
