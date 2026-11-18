import Foundation

/// Containers and their apps, persisted per container (`container.json` + `apps.json`).
/// Shared by the app and the CLI; writes go through a file lock.
public final class LibraryStore: @unchecked Sendable {
    private var storedContainers: [Container] = []
    private var storedApps: [AppEntry] = []
    private let lock = NSLock()

    public var containers: [Container] { lock.withLock { storedContainers } }
    public var apps: [AppEntry] { lock.withLock { storedApps } }

    public init() { reload() }

    public func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: CellPaths.containers, includingPropertiesForKeys: nil)) ?? []
        var loadedContainers: [Container] = []
        var loadedApps: [AppEntry] = []
        for dir in dirs where FileOps.isDirectory(dir) {
            guard let container = JSONStore.loadIfPresent(Container.self, from: dir.appendingPathComponent("container.json")) else { continue }
            loadedContainers.append(container)
            loadedApps += JSONStore.loadIfPresent([AppEntry].self, from: dir.appendingPathComponent("apps.json")) ?? []
        }
        loadedContainers.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.createdAt < rhs.createdAt
        }
        lock.withLock {
            storedContainers = loadedContainers
            storedApps = loadedApps
        }
    }

    // MARK: Queries

    public func container(id: UUID?) -> Container? {
        guard let id else { return nil }
        return containers.first { $0.id == id }
    }

    public func app(id: UUID) -> AppEntry? { apps.first { $0.id == id } }

    public func apps(in containerID: UUID) -> [AppEntry] {
        apps.filter { $0.containerID == containerID }
    }

    public var defaultContainer: Container? {
        containers.first { $0.isDefault && $0.platform == .windows } ?? containers.first { $0.platform == .windows }
    }

    // MARK: Containers

    @discardableResult
    public func createContainer(name: String, platform: PlatformKind = .windows, runtimeID: String? = nil,
                                makeDefault: Bool = false) throws -> Container {
        try CellPaths.ensureDirectories()
        var container = Container(name: name, platform: platform, runtimeID: runtimeID)
        container.isDefault = makeDefault || (platform == .windows && !containers.contains { $0.platform == .windows })
        try FileManager.default.createDirectory(at: container.prefixURL, withIntermediateDirectories: true)
        if container.isDefault {
            for var other in containers where other.isDefault {
                other.isDefault = false
                try save(other)
            }
        }
        try save(container)
        try JSONStore.save([AppEntry](), to: container.appsURL)
        reload()
        return container
    }

    public func save(_ container: Container) throws {
        try withFileLock(container.metadataURL) {
            try JSONStore.save(container, to: container.metadataURL)
        }
        lock.withLock {
            if let index = storedContainers.firstIndex(where: { $0.id == container.id }) { storedContainers[index] = container } else { storedContainers.append(container) }
        }
    }

    public func setDefault(_ container: Container) throws {
        for var other in containers where other.isDefault && other.id != container.id {
            other.isDefault = false
            try save(other)
        }
        var updated = container
        updated.isDefault = true
        try save(updated)
        reload()
    }

    /// Deletes the container folder (prefix, apps, settings). Callers stop Wine first.
    public func deleteContainer(_ container: Container) throws {
        for app in apps(in: container.id) {
            if let shortcut = app.shortcutPath { ShortcutBuilder.removeShortcut(at: shortcut) }
        }
        try FileManager.default.removeItem(at: container.directory)
        reload()
    }

    // MARK: Apps

    /// Adds or replaces an app (read-modify-write under a lock so the CLI and app never clobber each other).
    public func save(_ app: AppEntry) throws {
        guard let container = container(id: app.containerID) else { return }
        try withFileLock(container.appsURL) {
            var list = JSONStore.loadIfPresent([AppEntry].self, from: container.appsURL) ?? []
            if let index = list.firstIndex(where: { $0.id == app.id }) { list[index] = app } else { list.append(app) }
            try JSONStore.save(list, to: container.appsURL)
        }
        lock.withLock {
            if let index = storedApps.firstIndex(where: { $0.id == app.id }) { storedApps[index] = app } else { storedApps.append(app) }
        }
    }

    /// Applies a change to the freshest copy on disk and returns the result.
    @discardableResult
    public func update(appID: UUID, _ mutate: (inout AppEntry) -> Void) throws -> AppEntry? {
        guard let current = app(id: appID), let container = container(id: current.containerID) else { return nil }
        var result: AppEntry?
        try withFileLock(container.appsURL) {
            var list = JSONStore.loadIfPresent([AppEntry].self, from: container.appsURL) ?? []
            guard let index = list.firstIndex(where: { $0.id == appID }) else { return }
            mutate(&list[index])
            result = list[index]
            try JSONStore.save(list, to: container.appsURL)
        }
        if let result {
            lock.withLock {
                if let index = storedApps.firstIndex(where: { $0.id == appID }) { storedApps[index] = result }
            }
        }
        return result
    }

    public func remove(_ app: AppEntry) throws {
        guard let container = container(id: app.containerID) else { return }
        if let shortcut = app.shortcutPath { ShortcutBuilder.removeShortcut(at: shortcut) }
        try withFileLock(container.appsURL) {
            var list = JSONStore.loadIfPresent([AppEntry].self, from: container.appsURL) ?? []
            list.removeAll { $0.id == app.id }
            try JSONStore.save(list, to: container.appsURL)
        }
        lock.withLock { storedApps.removeAll { $0.id == app.id } }
    }

    // MARK: Runtime state

    public func state(for container: Container) -> ContainerState {
        JSONStore.loadIfPresent(ContainerState.self, from: container.stateURL) ?? ContainerState()
    }

    public func saveState(_ state: ContainerState, for container: Container) {
        try? withFileLock(container.stateURL) { try JSONStore.save(state, to: container.stateURL) }
    }
}
