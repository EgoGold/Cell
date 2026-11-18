import SwiftUI
import Virtualization
import CellCore

/// One virtual machine: what it is, starting and stopping it, its installer and its size.
struct VirtualMachineDetailView: View {
    @Bindable var model: AppModel
    let machine: VirtualMachine
    @Environment(\.openWindow) private var openWindow
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(spacing: 14) {
                    Image(systemName: machine.guest.symbol).font(.system(size: 34)).frame(width: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.name).font(.largeTitle.weight(.bold))
                        Text("\(machine.guest.displayName) virtual machine · \(machine.nextStartSummary)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRunning(machine) {
                        Button("Show Window") { openWindow(id: "vm", value: machine.id) }
                        Button("Shut Down") { model.shutDown(machine) }
                    } else {
                        Button {
                            model.start(machine) { openWindow(id: "vm", value: $0) }
                        } label: {
                            Label(machine.guest == .macOS && !machine.isInstalled ? "Install macOS" : "Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.virtualizationSupported)
                    }
                }

                SectionCard("Experimental", systemImage: "flask") {
                    Text("Virtual machines are an experimental part of Cell: they run a whole system you install yourself, and some things (graphics, sound, sharing files) are basic.")
                        .foregroundStyle(.secondary)
                    if case .experimental(let note) = machine.guest.support { Text(note).foregroundStyle(.secondary) }
                }

                SectionCard("Installation", systemImage: "opticaldisc") {
                    if machine.isInstalled {
                        Text("Installed. The machine starts from its own disk.").foregroundStyle(.secondary)
                    } else if let media = machine.installMedia {
                        LabeledContent("Installer", value: media)
                        if machine.guest == .macOS {
                            Text("The first start installs macOS from the restore image; then the machine starts macOS.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("The installer is attached like a USB stick. Install the system onto the machine's disk, shut it down, then remove the installer so it starts from the disk.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Installation Finished — Remove Installer") { model.finishInstallation(machine) }
                                .disabled(model.isRunning(machine))
                        }
                    } else if machine.kernel != nil {
                        Text("Starts a Linux kernel directly (advanced setup from the command line).").foregroundStyle(.secondary)
                    } else {
                        Text("No installer attached.").foregroundStyle(.secondary)
                    }
                }

                SectionCard("Hardware", systemImage: "cpu") {
                    Stepper("Processors: \(machine.cpuCount)", value: binding(\.cpuCount), in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("Memory: \(machine.memoryMiB / 1024) GB", value: Binding(
                        get: { machine.memoryMiB / 1024 },
                        set: { value in var updated = machine; updated.memoryMiB = value * 1024; model.updateVirtualMachine(updated) }),
                            in: 1...max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 2))
                    LabeledContent("Disk", value: "\(machine.diskGiB) GB (uses space only as the system writes)")
                    DisplayChoicePicker(title: "Display", selection: binding(\.displayID), automatic: "Any (\(machine.displayWidth) × \(machine.displayHeight) window)")
                    if machine.displayID != nil {
                        Text("The machine's window opens on that display and its screen takes the display's resolution.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Changes apply the next time the machine starts.").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.isRunning(machine))

                SectionCard("Files", systemImage: "folder") {
                    LabeledContent("Location") {
                        Text(machine.bundle.path).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([machine.bundle]) }
                        Button("Console Log") { NSWorkspace.shared.open(machine.consoleLogURL) }
                        Spacer()
                        Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                    }
                    Text("A virtual machine is one self-contained .cellvm folder: copy it to another Mac and import it there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(machine.name)
        .confirmationDialog("Move “\(machine.name)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.delete(machine) }
        } message: {
            Text("Its disk and everything installed in it go to the Trash. You can restore it from there until you empty the Trash.")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<VirtualMachine, T>) -> Binding<T> {
        Binding(get: { machine[keyPath: keyPath] },
                set: { value in var updated = machine; updated[keyPath: keyPath] = value; model.updateVirtualMachine(updated) })
    }
}

/// Creates a virtual machine from an installer image the user brings.
struct NewVirtualMachineSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var guest: GuestSystem = .linux
    @State private var installer: URL?
    @State private var cpuCount = max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 8))
    @State private var memoryGB = 4
    @State private var diskGB = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("New Virtual Machine").font(.title2.weight(.semibold))
                ExperimentalBadge()
            }
            Text("A virtual machine runs a whole operating system in a window, using the Mac's built-in hypervisor. Cell doesn't include any system: choose an installer image you have.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("System", selection: $guest) {
                    ForEach(GuestSystem.allCases) { system in
                        Text(label(for: system)).tag(system).disabled(!system.support.canCreate)
                    }
                }
                .onChange(of: guest) { _, value in
                    memoryGB = value.defaultMemoryMiB / 1024
                    diskGB = value.defaultDiskGiB
                    installer = nil
                }
                switch guest.support {
                case .experimental(let note), .unavailable(let note):
                    Text(note).font(.caption).foregroundStyle(.secondary)
                case .ready:
                    EmptyView()
                }
                TextField("Name", text: $name, prompt: Text(guest.displayName))
                LabeledContent("Installer") {
                    HStack {
                        Text(installer?.lastPathComponent ?? "None").foregroundStyle(installer == nil ? .secondary : .primary)
                        Button("Choose…") {
                            installer = Panels.chooseFiles(title: guest.installerHint, extensions: guest.installerTypes).first
                        }
                        .disabled(guest.installerTypes.isEmpty)
                    }
                }
                Text(guest.installerHint).font(.caption).foregroundStyle(.secondary)
                Stepper("Processors: \(cpuCount)", value: $cpuCount, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: 1...max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 2))
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 8...2048, step: 8)
            }
            .formStyle(.grouped)
            HStack {
                Button("Import Existing…") {
                    if let url = Panels.chooseFiles(title: "Choose a .cellvm folder", allowFolders: true, allowFiles: false).first {
                        model.importVirtualMachine(url)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createVirtualMachine(name: name.isEmpty ? guest.displayName : name, guest: guest, installer: installer,
                                               cpuCount: cpuCount, memoryMiB: memoryGB * 1024, diskGiB: diskGB)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!guest.support.canCreate || (guest == .macOS && installer == nil) || !model.virtualizationSupported)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func label(for system: GuestSystem) -> String {
        switch system.support {
        case .ready: return system.displayName
        case .experimental: return "\(system.displayName) (experimental)"
        case .unavailable: return "\(system.displayName) (not possible on a Mac yet)"
        }
    }
}

/// The window of a running virtual machine.
struct VirtualMachineWindow: View {
    @Bindable var model: AppModel
    let machineID: UUID?

    var body: some View {
        if let machineID, let session = model.vmSessions[machineID] {
            VirtualMachineScreen(virtualMachine: session.virtualMachine)
                .frame(minWidth: 640, minHeight: 400)
                .background(WindowPlacer(displayID: session.machine.displayID))
                .navigationTitle(session.machine.name)
                .toolbar {
                    ToolbarItemGroup {
                        Button("Shut Down", systemImage: "power") { model.shutDown(session.machine) }
                        Button("Turn Off", systemImage: "xmark.octagon") { model.forceStop(session.machine) }
                    }
                }
        } else {
            EmptyStateView(title: "Not running", systemImage: "desktopcomputer",
                           message: "Start the virtual machine from Cell's window.")
                .frame(minWidth: 480, minHeight: 300)
        }
    }
}

/// Shows the machine's display and passes keyboard, mouse and trackpad input to it.
struct VirtualMachineScreen: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine { view.virtualMachine = virtualMachine }
    }
}
