import SwiftUI
import CellCore

struct AppDetailView: View {
    @Bindable var model: AppModel
    let appID: UUID

    var body: some View {
        if let app = model.app(appID) {
            AppDetailContent(model: model, app: app)
        } else {
            EmptyStateView(title: "App not found", systemImage: "questionmark.app", message: "It was removed from the library.")
        }
    }
}

private struct AppDetailContent: View {
    let model: AppModel
    let app: AppEntry
    @State private var argumentsText = ""
    @State private var showRemoveConfirmation = false
    @State private var storageUsage: AppStorageUsage?
    @State private var checkedStorage = false
    @State private var steamLauncherFailure: DiagnosticFinding?
    @State private var unityDirectoryFailure: DiagnosticFinding?

    private var container: Container? { model.container(app.containerID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header
                SectionCard("Storage", systemImage: "internaldrive") {
                    if let storageUsage {
                        Text(storageUsage.bytes.byteDescription).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(storageDescription(storageUsage.scope)).foregroundStyle(.secondary)
                    } else {
                        Text(checkedStorage ? "Installation size unavailable" : "Measuring installation…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let steamLauncherFailure {
                    SectionCard("Recent Steam error", systemImage: "stethoscope") {
                        diagnostic(steamLauncherFailure)
                    }
                }
                if let unityDirectoryFailure,
                   model.lastOutcome[app.id]?.findings.contains(where: { $0.id == unityDirectoryFailure.id }) != true {
                    SectionCard("Recent game error", systemImage: "stethoscope") {
                        diagnostic(unityDirectoryFailure)
                    }
                }
                if let outcome = model.lastOutcome[app.id], !outcome.findings.isEmpty { diagnostics(outcome) }
                graphicsSection
                fixesSection
                displaySection
                launchSection
                detectedSection
                dangerZone
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(app.name)
        .task(id: app.lastPlayedAt) {
            steamLauncherFailure = container.flatMap { LogAnalyzer.steamLauncherFailure(for: app, in: $0) }
        }
        .task(id: app) {
            guard let container else { checkedStorage = true; return }
            while !Task.isCancelled {
                let (usage, startupFailure) = await Task.detached(priority: .utility) {
                    (AppStorageUsage.measure(app, in: container), LogAnalyzer.recentUnityDirectoryFailure(for: app, in: container))
                }.value
                guard !Task.isCancelled else { return }
                storageUsage = usage
                unityDirectoryFailure = startupFailure
                checkedStorage = true
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear { argumentsText = app.settings.extraArguments.joined(separator: " ") }
    }

    private func storageDescription(_ scope: AppStorageUsage.Scope) -> String {
        switch scope {
        case .steamInstallation: return "Steam installation. Saves and shared caches are separate."
        case .installationFolder: return "Estimated space used by the app’s installation folder."
        case .programFile: return "Program file only. Cell couldn’t identify a dedicated installation folder."
        case .steamProgramFiles: return "Steam program files. Game libraries and user data are separate."
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            AppArtworkView(app: app)
                .frame(width: 150, height: 184)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AppIconView(app: app, size: 36)
                    Text(app.name).font(.largeTitle.weight(.bold)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let container { Badge(text: container.name, systemImage: "shippingbox") }
                    if app.kind == .steamGame { Badge(text: "Steam", color: .blue, systemImage: "gamecontroller") }
                    if let engine = app.analysis?.engineDescription { Badge(text: engine) }
                    if let working = app.learned.workingBackend { Badge(text: "Works with \(working.displayName)", color: .green, systemImage: "checkmark.seal") }
                }
                if let status = model.launchStatus[app.id] {
                    Label(status, systemImage: "hourglass").foregroundStyle(Color.accentColor)
                } else if let last = app.lastPlayedAt {
                    Text("Last played \(last.formatted(.relative(presentation: .named))) · \(app.totalPlayTime.playTimeDescription) in total")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    PlayButton(model: model, app: app)
                    if app.shortcutPath == nil {
                        Button {
                            model.addToApplications(app)
                        } label: {
                            Label("Add to Applications", systemImage: "square.and.arrow.down.on.square")
                        }
                        .controlSize(.large)
                        .help("Creates an app in your Applications folder that starts \(app.name) directly")
                    } else {
                        Button {
                            if let path = app.shortcutPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        } label: {
                            Label("In Applications", systemImage: "checkmark.circle")
                        }
                        .controlSize(.large)
                    }
                    if app.kind == .steamGame, let container {
                        Button {
                            model.openSteamFriends(container)
                        } label: {
                            Label("Steam Friends", systemImage: "person.2")
                        }
                        .controlSize(.large)
                        .help("Invite friends from Steam's friends list when the in-game overlay won't open")
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Graphics

    private var graphicsSection: some View {
        SectionCard("Engines", systemImage: "bolt") {
            if let choice = model.engineChoice(for: app) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(Color.accentColor)
                    Text(choice.runtime.shortName).font(.headline)
                    if app.settings.runtimeOverride == nil { Badge(text: "Autopilot", color: .accentColor, systemImage: "wand.and.stars") }
                }
                Text("Wine engine: \(choice.reason)."
                     + (choice.fallbacks.isEmpty ? "" : " If every graphics engine crashes, Cell tries \(choice.fallbacks.map(\.name).joined(separator: ", then ")).")
                ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            if let decision = model.decision(for: app) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: decision.backend.symbol).foregroundStyle(Color.accentColor)
                    Text(decision.backend.displayName).font(.title3.weight(.semibold))
                    if app.settings.backendOverride == nil { Badge(text: "Autopilot", color: .accentColor, systemImage: "wand.and.stars") }
                }
                Text(decision.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !decision.fallbacks.isEmpty {
                    Text("If it crashes on start, Cell tries \(decision.fallbacks.map(\.displayName).joined(separator: ", then ")) automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Install a Wine engine to see which graphics engine this app will use.").foregroundStyle(.secondary)
            }
            Divider()
            Picker("Graphics", selection: binding(\.settings.backendOverride)) {
                Text("Automatic (recommended)").tag(GraphicsBackend?.none)
                ForEach(GraphicsBackend.allCases) { backend in
                    Text(backend.displayName).tag(Optional(backend))
                }
            }
            .frame(maxWidth: 420)
            if model.runtimes.count > 1 {
                Picker("Wine engine", selection: binding(\.settings.runtimeOverride)) {
                    Text("Automatic (recommended)").tag(String?.none)
                    ForEach(model.runtimes) { runtime in Text(runtime.name).tag(Optional(runtime.id)) }
                }
                .frame(maxWidth: 420)
            }
            Toggle("Try other engines automatically if the app crashes on start", isOn: binding(\.settings.autoFallback))
            if !app.learned.failedBackends.isEmpty || app.learned.workingBackend != nil {
                HStack {
                    if !app.learned.failedBackends.isEmpty {
                        Text("Crashed with: \(app.learned.failedBackends.map(\.displayName).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget What Cell Learned") { model.resetLearned(app) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Fixes

    private var fixesSection: some View {
        let fixes = model.fixes(for: app)
        return SectionCard("Fixes", systemImage: "puzzlepiece.extension") {
            if fixes.plugins.isEmpty {
                Text("No plugin applies to this app. Plugins fix specific games; anyone can write one.").foregroundStyle(.secondary)
            } else {
                ForEach(fixes.plugins) { plugin in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.manifest.name).font(.headline)
                            if let summary = plugin.manifest.summary { Text(summary).font(.callout).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !app.settings.disabledPlugins.contains(plugin.id) },
                            set: { enabled in
                                var updated = app
                                if enabled { updated.settings.disabledPlugins.removeAll { $0 == plugin.id } }
                                else { updated.settings.disabledPlugins.append(plugin.id) }
                                model.save(updated)
                            }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                }
                ForEach(Array(fixes.notes.enumerated()), id: \.offset) { _, note in
                    Label(note.text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Display & input

    private var displaySection: some View {
        SectionCard("Display & input", systemImage: "display") {
            Picker("Scrolling", selection: binding(\.settings.scrollMode)) {
                Text("Container default").tag(ScrollMode?.none)
                ForEach(ScrollMode.allCases) { mode in Text(mode.displayName).tag(Optional(mode)) }
            }
            optionalBoolPicker("High resolution (Retina)", keyPath: \.settings.highResolution)
            DisplayChoicePicker(title: "Display", selection: binding(\.settings.displayID), automatic: "Same as the translation layer")
                .help("Experimental: the game's resolution follows this display, and Unity games start on it.")
            optionalBoolPicker("Full display resolution", keyPath: \.settings.nativeResolution)
                .help("Sharp, pixel-for-pixel picture: the game's resolution is set to the display's, and games that don't say they handle high DPI (most Unreal games) are marked DPI-aware so Wine doesn't draw them at half size and stretch them.")
            optionalBoolPicker("Fullscreen locks the display", keyPath: \.settings.captureDisplays)
            if app.isGame {
                optionalBoolPicker("Start fullscreen", keyPath: \.settings.startFullscreen)
                    .help("Applies when the game opens again. Off uses the game's saved display mode.")
            }
            Picker("Mouse capture (DirectInput)", selection: binding(\.settings.mouseWarp)) {
                Text("Container default").tag(MouseWarpMode?.none)
                ForEach(MouseWarpMode.allCases) { mode in Text(mode.displayName).tag(Optional(mode)) }
            }
            DisclosureGroup("Advanced input") {
                Picker("Cursor capture method", selection: binding(\.settings.cursorCapture)) {
                    Text("Automatic").tag(CursorCaptureMethod?.none)
                    ForEach(CursorCaptureMethod.allCases) { method in Text(method.displayName).tag(Optional(method)) }
                }
                optionalBoolPicker("Lock window while capturing mouse", keyPath: \.settings.lockWindowWhenCaptured)
                optionalBoolPicker("Restore input after switching apps", keyPath: \.settings.recoverInputOnFocus)
                Text("Applies only to this game. Restart it after changing these options. Legacy capture requires Accessibility access for Wine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Windows version", selection: binding(\.settings.windowsVersion)) {
                Text("Container default").tag(WindowsVersion?.none)
                ForEach(WindowsVersion.allCases) { version in Text(version.displayName).tag(Optional(version)) }
            }
            if app.kind == .steamGame || app.steamAppID != nil {
                Picker("Steam overlay", selection: binding(\.settings.steamOverlay)) {
                    ForEach(OverlayMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                Text("Turn the overlay off if the game crashes when you press Shift-Tab or “Invite friends”; use Steam Friends above to invite instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func optionalBoolPicker(_ title: String, keyPath: WritableKeyPath<AppEntry, Bool?>) -> some View {
        Picker(title, selection: binding(keyPath)) {
            Text("Container default").tag(Bool?.none)
            Text("On").tag(Optional(true))
            Text("Off").tag(Optional(false))
        }
    }

    // MARK: Launch options

    private var launchSection: some View {
        SectionCard("Launch options", systemImage: "terminal") {
            TextField("Extra arguments", text: $argumentsText, prompt: Text("e.g. -dx11 -windowed"))
                .onSubmit(saveArguments)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Press Return to save. Arguments are added after the ones Cell and plugins choose.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: saveArguments).controlSize(.small)
            }
            KeyValueEditor(title: "Environment variables", values: binding(\.settings.environment))
            if let windowsPath = app.windowsPath {
                LabeledContent("Program", value: windowsPath).font(.caption).textSelection(.enabled)
            }
        }
    }

    private func saveArguments() {
        var updated = app
        updated.settings.extraArguments = LnkFile.splitArguments(argumentsText)
        model.save(updated)
    }

    // MARK: Detected

    private var detectedSection: some View {
        SectionCard("What Cell detected", systemImage: "magnifyingglass") {
            if let analysis = app.analysis {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Architecture", analysis.architecture.displayName + (analysis.isDotNet ? " · .NET" : ""))
                    row("Graphics", analysis.graphicsAPIs.isEmpty ? "None detected" : analysis.graphicsAPIs.sorted().map(\.displayName).joined(separator: ", "))
                    if let engine = analysis.engineDescription { row("Engine", engine) }
                    if let product = analysis.productName { row("Product", [product, analysis.fileVersion].compactMap { $0 }.joined(separator: " ")) }
                    if let company = analysis.companyName { row("Publisher", company) }
                    if let steam = app.steamAppID ?? analysis.steamAppID { row("Steam app", steam) }
                    if !analysis.antiCheat.isEmpty { row("Anti-cheat", analysis.antiCheat.joined(separator: ", ")) }
                }
                ForEach(analysis.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Not analyzed yet.").foregroundStyle(.secondary)
            }
            Button("Check Again") { model.reanalyze(app) }.controlSize(.small)
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func diagnostics(_ outcome: LaunchOutcome) -> some View {
        SectionCard("Last launch", systemImage: "stethoscope") {
            Text("Ran \(outcome.duration.playTimeDescription.lowercased()) with \(outcome.backend.displayName), exit code \(outcome.exitCode).")
                .foregroundStyle(.secondary)
            ForEach(outcome.findings) { finding in
                diagnostic(finding)
            }
            if let log = outcome.logURL {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }.controlSize(.small)
            }
        }
    }

    private func diagnostic(_ finding: DiagnosticFinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(finding.title, systemImage: finding.severity == .error ? "xmark.octagon.fill" : (finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                .foregroundStyle(finding.severity == .error ? .red : (finding.severity == .warning ? .orange : .secondary))
            if let advice = finding.advice { Text(advice).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var dangerZone: some View {
        HStack {
            Toggle("Favorite", isOn: binding(\.isFavorite))
            Toggle("Hide from Library", isOn: binding(\.isHidden))
            Spacer()
            Button("Remove from Library…") { showRemoveConfirmation = true }
            Button("Uninstall…", role: .destructive) { model.pendingUninstall = app }
                .help(model.uninstallPlan(for: app).explanation)
        }
        .confirmationDialog("Remove “\(app.name)” from the library?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) { model.remove(app) }
        } message: {
            Text("The program stays installed in its container; only the library entry and its Applications shortcut are removed.")
        }
    }

    // MARK: Binding helper

    private func binding<T>(_ keyPath: WritableKeyPath<AppEntry, T>) -> Binding<T> {
        Binding(
            get: { app[keyPath: keyPath] },
            set: { newValue in
                var updated = model.app(app.id) ?? app
                updated[keyPath: keyPath] = newValue
                model.save(updated)
            })
    }
}

/// Editable list of KEY=value pairs.
struct KeyValueEditor: View {
    let title: String
    @Binding var values: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.system(.callout, design: .monospaced))
                    Text("=").foregroundStyle(.secondary)
                    Text(values[key] ?? "").font(.system(.callout, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button {
                        values.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("NAME", text: $newKey).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                TextField("value", text: $newValue).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let key = newKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    values[key] = newValue
                    newKey = ""
                    newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
