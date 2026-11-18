import SwiftUI
import CellCore

/// Wine configuration, organised the way a Mac user thinks about it (no winecfg).
struct ContainerSettingsView: View {
    let model: AppModel
    let containerID: UUID

    var body: some View {
        if let container = model.container(containerID) {
            SettingsForm(model: model, container: container)
        }
    }
}

private struct SettingsForm: View {
    let model: AppModel
    let container: Container
    @State private var steamArguments = ""
    @State private var showRegistry = false
    @State private var showHostRewrites = false

    private var display: DisplayInfo { DisplayInfo.resolve(container.settings.displayID) }

    var body: some View {
        Form {
            Section("Network") {
                Button("Edit Host/DNS Rewriter…") { showHostRewrites = true }
                Button("Network Assistant…") { model.selection = .network }
                Toggle("Open router ports while playing (NAT-PMP / PCP / UPnP)", isOn: binding(\.settings.mapPortsWhilePlaying))
            }
            Section {
                LabeledContent("Windows registry") {
                    Button("Open Registry Editor…") { showRegistry = true }
                }
            } header: {
                Text("Registry")
            } footer: {
                Text("For changes no setting covers. Cell writes its own settings into the registry before programs start.")
            }

            Section("Install") {
                LabeledContent("Steam") {
                    if SteamIntegration.isInstalled(in: container) {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install Steam") { model.installSteam(in: container) }
                    }
                }
                LabeledContent("Epic Games Launcher") {
                    Button("Install") { model.installEpicGamesLauncher(in: container) }
                }
                LabeledContent("Visual C++ runtimes") {
                    Button("Install") { model.installVisualCpp(in: container) }
                }
                LabeledContent(".NET Framework 4.8") {
                    if CellServices.hasDotNetFramework(container) {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install") { model.installDotNet(in: container) }
                            .help("Microsoft's .NET in place of Wine Mono, for .NET programs that need it (Plain Craft Launcher, many tools). About 110 MB; a few minutes.")
                    }
                }
                if !container.isDefault {
                    LabeledContent("Default translation layer") {
                        Button("Make Default") { model.makeDefault(container) }
                    }
                }
            }

            Section {
                Picker("Wine engine", selection: binding(\.runtimeID)) {
                    if container.runtimeID == nil { Text("Recommended").tag(String?.none) }
                    ForEach(model.runtimes) { runtime in Text(runtime.name).tag(Optional(runtime.id)) }
                }
                Picker("Graphics engine", selection: binding(\.settings.preferredBackend)) {
                    Text("Automatic per game (recommended)").tag(GraphicsBackend?.none)
                    ForEach(GraphicsBackend.allCases) { backend in Text("Prefer \(backend.displayName)").tag(Optional(backend)) }
                }
            } header: {
                Text("Engines")
            } footer: {
                Text("One translation layer runs every graphics engine. Cell chooses D3DMetal, DXMT, DXVK or WineD3D for each game when it starts.")
            }

            Section {
                Toggle("High resolution (Retina)", isOn: binding(\.settings.highResolution))
                Picker("Text and UI size", selection: binding(\.settings.dpiMode)) {
                    ForEach(DPIMode.allCases) { mode in
                        Text(mode == .automatic ? "Match Mac display (\(display.automaticDPI) DPI)" : mode.displayName).tag(mode)
                    }
                }
                .disabled(!container.settings.highResolution)
                if container.settings.dpiMode == .custom {
                    Stepper("Custom DPI: \(container.settings.customDPI)", value: binding(\.settings.customDPI), in: 96...288, step: 12)
                }
                DisplayChoicePicker(title: "Display", selection: binding(\.settings.displayID),
                                    automatic: "Main display (\(DisplayInfo.main().name))")
                Toggle("Games use the display's full resolution", isOn: binding(\.settings.nativeGameResolution))
                Toggle("Start games fullscreen", isOn: binding(\.settings.startGamesFullscreen))
                Toggle("Pretend to change resolution (experimental; mouse clicks can miss)", isOn: binding(\.settings.virtualDisplayModes))
                Toggle("Fullscreen games lock the display", isOn: binding(\.settings.fullscreenLocksDisplay))
            } header: {
                Text("Display")
            } footer: {
                Text("Full resolution sets Unreal and Unity games to \(display.pixelWidth)×\(display.pixelHeight), borderless fullscreen and 100% 3D resolution before they start; quality settings stay as they are. Choosing another display (experimental) sets games and text size up for it, and Unity games start on it; Windows still opens other programs on the main display first, so drag their window over. Locking the display blocks Mission Control, Cmd-Tab and trackpad gestures, so leave it off unless a game needs it.")
            }

            Section("Keyboard, mouse and trackpad") {
                Toggle("⌘ Command acts as Ctrl", isOn: binding(\.settings.commandAsControl))
                Toggle("⌥ Option acts as Alt", isOn: binding(\.settings.optionAsAlt))
                Picker("Scrolling", selection: binding(\.settings.scrollMode)) {
                    ForEach(ScrollMode.allCases) { mode in
                        Text(mode == .automatic ? "Automatic (notched in games, smooth in apps)" : mode.displayName).tag(mode)
                    }
                }
                Picker("Mouse capture (DirectInput games)", selection: binding(\.settings.mouseWarp)) {
                    ForEach(MouseWarpMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
            }

            Section {
                Toggle("Metal performance HUD", isOn: binding(\.settings.metalHUD))
                Toggle("MetalFX upscaling", isOn: binding(\.settings.metalFXUpscaling))
                if container.settings.metalFXUpscaling {
                    LabeledContent("DXMT upscale factor") {
                        Slider(value: binding(\.settings.metalFXScale), in: 1...2, step: 0.25) { EmptyView() }
                            .frame(maxWidth: 220)
                        Text(String(format: "%.2f×", container.settings.metalFXScale)).monospacedDigit()
                    }
                }
                Picker("Frame rate limit (DXMT)", selection: binding(\.settings.frameRateLimit)) {
                    Text("Unlimited").tag(0)
                    ForEach(display.validFrameRateLimits, id: \.self) { fps in Text("\(fps) fps").tag(fps) }
                }
                Toggle("Ray tracing (D3DMetal, M3 or newer)", isOn: binding(\.settings.rayTracing))
            } header: {
                Text("Graphics")
            } footer: {
                Text("Frame rate limits divide your display's refresh rate (\(Int(display.refreshRate)) Hz) evenly, which keeps frame pacing smooth.")
            }

            Section("Performance") {
                Picker("Synchronization", selection: binding(\.settings.syncMode)) {
                    ForEach(SyncMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                Toggle("Keep Wine ready for faster launches", isOn: binding(\.settings.keepEngineWarm))
                Toggle("Report AVX to games that require it", isOn: binding(\.settings.advertiseAVX))
            }

            Section {
                Picker("Language", selection: binding(\.settings.language)) {
                    ForEach(ContainerLanguage.allCases) { language in Text(language.displayName).tag(language) }
                }
                let resolution = LanguageResolver.resolve(container.settings.language)
                let text = LanguageResolver.textLanguage(for: container.settings.language)
                if container.settings.language == .automatic {
                    LabeledContent("Programs show", value: resolution.language.displayName)
                }
                if text.language != resolution.language {
                    LabeledContent("Typing works for", value: text.language.displayName)
                }
                Toggle("Fonts for every language", isOn: binding(\.settings.cjkFontFallbacks))
                    .help("Programs and games find your Mac's fonts for Chinese, Japanese, Korean, Arabic, Hebrew, Hindi, Thai and other scripts instead of showing boxes.")
            } header: {
                Text("Language and fonts")
            } footer: {
                Text(LanguageResolver.resolve(container.settings.language).reason + " "
                     + LanguageResolver.textLanguage(for: container.settings.language).reason
                     + " Programs show the display language; typed Chinese, Japanese or Korean text works whenever such an input method is enabled on your Mac.")
            }

            Section {
                Toggle("Fix Steam's black or blank window", isOn: binding(\.settings.steamStabilityMode))
                Picker("When a game needs another graphics engine", selection: binding(\.settings.steamRestartPolicy)) {
                    ForEach(SteamRestartPolicy.allCases) { policy in Text(policy.displayName).tag(policy) }
                }
                TextField("Extra Steam arguments", text: $steamArguments, prompt: Text("e.g. -no-browser"))
                    .onSubmit {
                        var updated = container
                        updated.settings.steamExtraArguments = LnkFile.splitArguments(steamArguments)
                        model.save(updated)
                    }
            } header: {
                Text("Steam")
            } footer: {
                Text("Steam draws its window with Chromium, which stays black or blank under Wine on macOS. Cell starts it through a small launcher that draws inside Steam's own process (Valve's file is kept as steamwebhelper_real.exe and restored when you turn this off), and downloads Steam's own updates in parallel from all of Valve's servers. Advanced: the launcher's Chromium switches can be changed with the environment variable CELL_WEBHELPER_FLAGS below.")
            }

            Section("Compatibility") {
                Picker("Windows version", selection: binding(\.settings.windowsVersion)) {
                    ForEach(WindowsVersion.allCases) { version in Text(version.displayName).tag(version) }
                }
                Toggle("Detailed logs (slower)", isOn: binding(\.settings.debugLogging))
                KeyValueEditor(title: "Environment variables", values: binding(\.settings.environment))
                KeyValueEditor(title: "DLL overrides (name = native,builtin)", values: binding(\.settings.dllOverrides))
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showHostRewrites) { HostRewritesEditor(model: model, container: container) }
        .sheet(isPresented: $showRegistry) {
            VStack(spacing: 0) {
                RegistryView(model: model, container: container)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showRegistry = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .onAppear { steamArguments = container.settings.steamExtraArguments.joined(separator: " ") }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Container, T>) -> Binding<T> {
        Binding(
            get: { container[keyPath: keyPath] },
            set: { newValue in
                var updated = model.container(container.id) ?? container
                updated[keyPath: keyPath] = newValue
                model.save(updated)
            })
    }
}
