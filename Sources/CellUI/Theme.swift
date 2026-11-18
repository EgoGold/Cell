import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CellCore

/// Design tokens. The whole UI reads spacing, radii and sizes from here so a redesign
/// can restyle Cell without touching screen logic.
public enum Theme {
    public static let spacing: CGFloat = 16
    public static let smallSpacing: CGFloat = 8
    public static let cornerRadius: CGFloat = 14
    public static let cardWidth: CGFloat = 180
    public static let cardArtHeight: CGFloat = 220
    public static let iconSize: CGFloat = 64
    public static let sidebarWidth: CGFloat = 230
    public static let accent = Color.accentColor
    public static let cardBackground = Color(nsColor: .controlBackgroundColor)
    public static let subtleBackground = Color.primary.opacity(0.05)
}

/// A rounded section used on detail pages.
struct SectionCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Loads images from disk once and keeps them.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [URL: NSImage] = [:]

    func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = images[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }

    func invalidate(_ url: URL?) { if let url { images.removeValue(forKey: url) } }
}

struct AppIconView: View {
    let app: AppEntry
    var size: CGFloat = Theme.iconSize

    var body: some View {
        Group {
            if let image = ImageCache.shared.image(app.iconURL) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "app.dashed")
                        .font(.system(size: size * 0.4)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Artwork for library cards: Steam capsule if available, otherwise the icon on a tinted backdrop.
struct AppArtworkView: View {
    let app: AppEntry

    var body: some View {
        ZStack {
            if let art = ImageCache.shared.image(app.artworkURL) {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                AppIconView(app: app, size: 84)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension GraphicsBackend {
    var symbol: String {
        switch self {
        case .d3dmetal: return "apple.logo"
        case .dxmt: return "bolt.fill"
        case .dxvk: return "cube.transparent"
        case .wined3d: return "square.stack.3d.up"
        }
    }
}

extension TimeInterval {
    var playTimeDescription: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "Less than a minute"
    }
}

extension Int64 {
    var byteDescription: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Native open panels (support .app bundles, folders and archives, which file importers handle poorly).
@MainActor
enum Panels {
    static func chooseFiles(title: String, extensions: [String]? = nil, allowFolders: Bool = false,
                            allowFiles: Bool = true, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = allowFiles
        panel.canChooseDirectories = allowFolders
        panel.allowsMultipleSelection = multiple
        panel.treatsFilePackagesAsDirectories = false
        if let extensions {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Experimental: choose one of the Mac's displays (or the automatic choice).
struct DisplayChoicePicker: View {
    let title: String
    @Binding var selection: String?
    let automatic: String

    var body: some View {
        let displays = DisplayInfo.all()
        Picker(selection: $selection) {
            Text(automatic).tag(String?.none)
            ForEach(displays) { display in
                Text(display.summary + (display.isMain ? " · main" : "")).tag(Optional(display.id))
            }
            if let id = selection, !displays.contains(where: { $0.id == id }) {
                Text("A display that isn't connected").tag(Optional(id))
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                ExperimentalBadge()
            }
        }
    }
}

/// Moves its window to a chosen display once, when it first appears.
struct WindowPlacer: NSViewRepresentable {
    let displayID: String?

    func makeNSView(context: Context) -> PlacerView { PlacerView(displayID: displayID) }
    func updateNSView(_ view: PlacerView, context: Context) {}

    final class PlacerView: NSView {
        let displayID: String?
        private var placed = false

        init(displayID: String?) {
            self.displayID = displayID
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !placed, let window, let displayID,
                  let screen = NSScreen.screens.first(where: { DisplayInfo.id(of: $0) == displayID }) else { return }
            placed = true
            DispatchQueue.main.async {
                let visible = screen.visibleFrame
                var frame = window.frame
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                window.setFrame(frame, display: true)
            }
        }
    }
}

/// Design snapshots draw the window into a PNG without it ever being visible on screen.
struct SnapshotWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderView { HiderView() }
    func updateNSView(_ view: HiderView, context: Context) {}

    final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard ProcessInfo.processInfo.environment["CELL_UI_SNAPSHOT"] != nil, let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }
}
