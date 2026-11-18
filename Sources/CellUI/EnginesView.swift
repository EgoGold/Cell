import SwiftUI
import CellCore

struct EnginesView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Engine").font(.largeTitle.weight(.bold))
                Text("Wine runs Windows programs. Graphics engines translate Direct3D to Metal. Cell combines them per game automatically, so one translation layer covers every game.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        model.selection = .setup
                        model.runSetup()
                    } label: {
                        Label(model.setupNeeded ? "Get Everything Automatically" : "Check Setup Again", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    Text(model.setupNeeded ? "Downloads and configures whatever is missing." : "Everything is installed.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        model.checkEngines(again: true)
                    } label: {
                        Label("Check Engines Again", systemImage: "checkmark.seal")
                    }
                    .disabled(model.engineCheckStatus != nil)
                    Text(model.engineCheckStatus ?? "Cell checks each engine pair once and never uses one that can't draw.")
                        .foregroundStyle(.secondary)
                }
                if model.canRunDirect3D11Games == false { NoDirect3D11Warning(model: model) }
                bottlesSection
                wineSection
                graphicsSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Engine")
    }

    // MARK: Bottles

    @ViewBuilder private var bottlesSection: some View {
        let pending = model.bottles.filter { bottle in !model.containers.contains { $0.importedFrom == bottle.prefix.path } }
        if !pending.isEmpty {
            SectionCard("Your games in other apps", systemImage: "arrow.down.doc") {
                Text("Bring Porting Kit, CrossOver and Whisky bottles into Cell with their Steam login, games and saves. Copies are instant and use no extra disk space.")
                    .foregroundStyle(.secondary)
                ForEach(pending) { bottle in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bottle.name).font(.headline)
                            Text(bottle.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") { model.importBottle(bottle) }
                    }
                }
            }
        }
    }

    // MARK: Wine

    private var wineSection: some View {
        SectionCard("Wine engines", systemImage: "cpu") {
            if model.runtimes.isEmpty {
                Text("No engine installed yet.").foregroundStyle(.secondary)
            }
            ForEach(model.runtimes) { runtime in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(runtime.name).font(.headline)
                            if model.containers.contains(where: { $0.isDefault && $0.runtimeID == runtime.id }) {
                                Badge(text: "Default", color: .green)
                            } else if runtime.id == model.services.runtimes.recommendedRuntime?.id {
                                Badge(text: "Recommended", color: .green)
                            }
                        }
                        HStack(spacing: 6) {
                            Badge(text: "Wine \(runtime.version)")
                            ForEach(runtime.bundledComponents, id: \.kind) { component in
                                Badge(text: "\(component.kind.displayName) \(component.version ?? "")", color: .accentColor)
                            }
                            if runtime.supportsD3DMetal == true { Badge(text: "D3DMetal-ready", color: .purple) }
                            if runtime.hasMono { Badge(text: ".NET") }
                        }
                        engineChecks(for: runtime)
                        let users = model.containers.filter { $0.runtimeID == runtime.id }.map(\.name)
                        if !users.isEmpty {
                            Text("Used by \(users.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !model.containers.contains(where: { $0.isDefault && $0.runtimeID == runtime.id }) {
                        Button("Make Default") { model.makeDefaultEngine(runtime) }.controlSize(.small)
                    }
                    Button("Remove", role: .destructive) { model.remove(runtime) }.controlSize(.small)
                }
                Divider()
            }

            Text("Download").font(.subheadline.weight(.semibold))
            ForEach(Catalog.wineEngines) { entry in
                catalogRow(entry, installed: model.runtimes.contains { $0.id == entry.id })
            }

            let wrappers = model.pendingImportSuggestions.filter { $0.url.pathExtension == "app" }
            if !wrappers.isEmpty {
                Text("Already on this Mac").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(wrappers) { suggestion in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                            Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") { model.importRuntime(suggestion.url) }
                    }
                }
                Text("Imports are copy-on-write clones: they take no extra disk space. Engines that contain DXMT or D3DMetal also make those available to your other engines.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Import Engine from Folder, App or Archive…") {
                let urls = Panels.chooseFiles(title: "Choose a Wine engine (folder, Wineskin/Porting Kit app, or .tar.xz/.tar.7z)",
                                              allowFolders: true)
                if let url = urls.first { model.importRuntime(url) }
            }
        }
    }

    /// What Cell's engine check found for each graphics engine on `runtime`.
    @ViewBuilder private func engineChecks(for runtime: WineRuntime) -> some View {
        let _ = model.engineCheckRevision
        let verifier = model.services.verifier
        ForEach(verifier.checkableBackends(for: runtime)) { backend in
            let check = verifier.check(runtime: runtime, backend: backend)
            let unknown = check?.isConclusive != true
            HStack(spacing: 6) {
                Image(systemName: unknown ? "clock" : (check!.runsDirect3D11 ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                    .foregroundStyle(unknown ? Color.secondary : (check!.runsDirect3D11 ? Color.green : Color.red))
                Text("\(backend.displayName): \(check?.summary ?? (model.engineCheckStatus == nil ? "not checked yet" : "checking…"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(check?.output ?? "")
        }
    }

    // MARK: Graphics

    private var graphicsSection: some View {
        SectionCard("Graphics engines", systemImage: "bolt") {
            componentRow(.d3dmetal,
                         description: "Apple's translator from the Game Porting Toolkit. Best for DirectX 12 and many DirectX 11 games. 64-bit games only.") {
                Menu("Import") {
                    ForEach(model.services.components.d3dMetalSources()) { source in
                        Button("From \(source.title)") { model.importD3DMetal(source.url) }
                    }
                    Button("From Game Porting Toolkit Disk Image or Folder…") {
                        if let url = Panels.chooseFiles(title: "Choose the Game Porting Toolkit .dmg or its redist folder",
                                                        extensions: ["dmg"], allowFolders: true).first {
                            model.importD3DMetal(url)
                        }
                    }
                    Divider()
                    Button("Get It from Apple…") { NSWorkspace.shared.open(Catalog.gptkDownloadPage) }
                }
                .fixedSize()
            }
            Divider()
            componentRow(.dxmt, description: "Open-source DirectX 10/11 to Metal. Usually the fastest choice for DirectX 11 games.") {
                HStack {
                    if let entry = Catalog.graphicsComponents.first(where: { $0.kind == .dxmt }),
                       !model.components.contains(where: { $0.id == "dxmt-\(entry.version)" }) {
                        Button("Download \(entry.version)") { model.install(entry) }.buttonStyle(.borderedProminent)
                    }
                    Button("Import…") {
                        if let url = Panels.chooseFiles(title: "Choose a DXMT release archive or folder", extensions: ["gz", "xz", "zip", "7z"],
                                                        allowFolders: true).first {
                            model.importDXMT(url)
                        }
                    }
                }
            }
            Divider()
            componentRow(.dxvk, description: "DirectX 9–11 through Vulkan and MoltenVK. A fallback for games the others can't run.") {
                Button("Import…") {
                    if let url = Panels.chooseFiles(title: "Choose a DXVK release archive or folder", extensions: ["gz", "xz", "zip"],
                                                    allowFolders: true).first {
                        model.importDXVK(url)
                    }
                }
            }
            Divider()
            HStack(alignment: .top) {
                Image(systemName: GraphicsBackend.wined3d.symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WineD3D").font(.headline)
                    Text("Built into every Wine engine. Used for DirectX 9 and older games.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func componentRow<Actions: View>(_ kind: ComponentKind, description: String, @ViewBuilder actions: () -> Actions) -> some View {
        let installed = model.components.filter { $0.kind == kind }
        let bundledIn = model.runtimes.filter { $0.bundled(kind) != nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: kind.backend.symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(kind.displayName).font(.headline)
                        if !installed.isEmpty || !bundledIn.isEmpty {
                            Badge(text: "Ready", color: .green, systemImage: "checkmark")
                        }
                    }
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                actions()
            }
            ForEach(installed) { component in
                HStack {
                    Text("\(component.kind.displayName) \(component.version)").font(.callout)
                    Text(URL(fileURLWithPath: component.origin).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { model.remove(component) }.controlSize(.small)
                }
                .padding(.leading, 30)
            }
        }
    }

    private func catalogRow(_ entry: CatalogEntry, installed: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(entry.name) \(entry.version)")
                    if entry.recommended { Badge(text: "Recommended", color: .green) }
                }
                Text(entry.notes).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Badge(text: "Installed", color: .green, systemImage: "checkmark")
            } else {
                Button("Download (\((entry.sizeBytes ?? 0).byteDescription))") { model.install(entry) }
            }
        }
    }

}
