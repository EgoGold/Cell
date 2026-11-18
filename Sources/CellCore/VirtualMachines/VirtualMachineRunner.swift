import Foundation
import Virtualization

/// Turns a `VirtualMachine` into a configuration for Apple's Virtualization framework.
public enum VirtualMachineConfigurator {
    /// Whether this Mac (and this build of Cell, which needs the virtualization entitlement) can run VMs.
    public static var isSupported: Bool { VZVirtualMachine.isSupported }

    public static func configuration(for machine: VirtualMachine) throws -> VZVirtualMachineConfiguration {
        guard isSupported else {
            throw VirtualMachineError.unsupported("This Mac can't run virtual machines (Apple silicon or an Intel Mac with virtualization is needed).")
        }
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = min(max(machine.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(machine.memoryMiB) << 20
        config.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let disk = try VZDiskImageStorageDeviceAttachment(url: machine.diskURL, readOnly: false)
        switch machine.guest {
        case .macOS:
            #if arch(arm64)
            try configureMac(config, machine: machine, disk: disk)
            #else
            throw VirtualMachineError.unsupported("macOS virtual machines need a Mac with Apple silicon.")
            #endif
        case .linux, .windows, .android:
            try configureGeneric(config, machine: machine, disk: disk)
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let address = macAddress(for: machine) { network.macAddress = address }
        config.networkDevices = [network]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        config.audioDevices = [sound]

        // The first serial console writes to console.log (Linux shows its boot messages there with console=hvc0).
        FileManager.default.createFile(atPath: machine.consoleLogURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: machine.consoleLogURL) {
            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: log)
            config.serialPorts = [console]
        }
        try config.validate()
        return config
    }

    /// Linux, Windows on Arm and Android: UEFI firmware (or a Linux kernel started directly).
    static func configureGeneric(_ config: VZVirtualMachineConfiguration, machine: VirtualMachine,
                                 disk: VZDiskImageStorageDeviceAttachment) throws {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = genericIdentifier(for: machine)
        config.platform = platform

        if let kernel = machine.kernelURL {
            let loader = VZLinuxBootLoader(kernelURL: kernel)
            loader.initialRamdiskURL = machine.initialRamdiskURL
            loader.commandLine = machine.kernelCommandLine ?? "console=hvc0"
            config.bootLoader = loader
        } else {
            let fm = FileManager.default
            let store = fm.fileExists(atPath: machine.efiVariablesURL.path)
                ? VZEFIVariableStore(url: machine.efiVariablesURL)
                : try VZEFIVariableStore(creatingVariableStoreAt: machine.efiVariablesURL)
            let loader = VZEFIBootLoader()
            loader.variableStore = store
            config.bootLoader = loader
        }

        // Windows has an NVMe driver built in, but none for virtio disks.
        var storage: [VZStorageDeviceConfiguration] = [
            machine.guest == .windows ? VZNVMExpressControllerDeviceConfiguration(attachment: disk)
                                      : VZVirtioBlockDeviceConfiguration(attachment: disk),
        ]
        if !machine.isInstalled, let media = machine.mediaURL, FileManager.default.fileExists(atPath: media.path) {
            let installer = try VZDiskImageStorageDeviceAttachment(url: media, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: installer))
        }
        config.storageDevices = storage

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: machine.displayWidth, heightInPixels: machine.displayHeight)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Copy and paste with the Mac (Linux guests with spice-vdagent).
        let spice = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = VZSpiceAgentPortAttachment()
        spice.ports[0] = port
        config.consoleDevices = [spice]
    }

    #if arch(arm64)
    static func configureMac(_ config: VZVirtualMachineConfiguration, machine: VirtualMachine,
                             disk: VZDiskImageStorageDeviceAttachment) throws {
        guard let modelData = try? Data(contentsOf: machine.hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: modelData),
              let identifierData = try? Data(contentsOf: machine.machineIdentifierURL),
              let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw VirtualMachineError.unsupported("This macOS virtual machine isn't prepared yet. Start it once to install macOS.")
        }
        guard model.isSupported else {
            throw VirtualMachineError.unsupported("This Mac can't run the macOS version this virtual machine was made for.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: machine.auxiliaryStorageURL)
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: machine.displayWidth, heightInPixels: machine.displayHeight,
                                                               pixelsPerInch: 144)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]
    }

    /// Reads the restore image and writes the machine's hardware model, identity and boot storage.
    public static func prepareMacInstallation(_ machine: VirtualMachine) async throws -> VZMacOSRestoreImage {
        guard let media = machine.mediaURL, FileManager.default.fileExists(atPath: media.path) else {
            throw VirtualMachineError.missingInstaller
        }
        let image: VZMacOSRestoreImage = try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: media) { result in continuation.resume(with: result) }
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VirtualMachineError.unsupported("This Mac can't run macOS \(image.operatingSystemVersion.majorVersion) in a virtual machine. Use a restore image for the macOS version on this Mac or older.")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: machine.hardwareModelURL.path) {
            try requirements.hardwareModel.dataRepresentation.write(to: machine.hardwareModelURL)
        }
        if !fm.fileExists(atPath: machine.machineIdentifierURL.path) {
            try VZMacMachineIdentifier().dataRepresentation.write(to: machine.machineIdentifierURL)
        }
        if !fm.fileExists(atPath: machine.auxiliaryStorageURL.path) {
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: machine.auxiliaryStorageURL, hardwareModel: requirements.hardwareModel, options: [])
        }
        return image
    }
    #endif

    /// Generic machines keep their identity (Windows activation and some Linux setups depend on it).
    static func genericIdentifier(for machine: VirtualMachine) -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: machine.machineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try? identifier.dataRepresentation.write(to: machine.machineIdentifierURL)
        return identifier
    }

    /// A stable network address, so the guest keeps its IP address and network settings.
    static func macAddress(for machine: VirtualMachine) -> VZMACAddress? {
        let file = machine.bundle.appendingPathComponent("MACAddress")
        if let text = try? String(contentsOf: file, encoding: .utf8), let address = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return address
        }
        let address = VZMACAddress.randomLocallyAdministered()
        try? address.string.write(to: file, atomically: true, encoding: .utf8)
        return address
    }
}

/// A running virtual machine. Use it on the main thread (the Virtualization framework's default queue).
@MainActor
public final class VirtualMachineSession: NSObject, VZVirtualMachineDelegate {
    public let machine: VirtualMachine
    public let virtualMachine: VZVirtualMachine
    /// Called when the guest shut down (nil) or the machine stopped with an error.
    public var onStop: ((Error?) -> Void)?

    public init(machine: VirtualMachine) throws {
        self.machine = machine
        virtualMachine = VZVirtualMachine(configuration: try VirtualMachineConfigurator.configuration(for: machine))
        super.init()
        virtualMachine.delegate = self
    }

    public var isRunning: Bool { [.running, .starting, .resuming, .paused, .pausing].contains(virtualMachine.state) }

    public func start() async throws {
        try await virtualMachine.start()
    }

    /// Asks the guest to shut down, like pressing the power button.
    public func requestShutdown() throws {
        try virtualMachine.requestStop()
    }

    /// Turns the machine off immediately (unsaved work in the guest is lost).
    public func forceStop() async throws {
        try await virtualMachine.stop()
    }

    #if arch(arm64)
    /// Installs macOS from the machine's restore image. Takes a while; reports 0…1.
    public func installMacOS(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let media = machine.mediaURL else { throw VirtualMachineError.missingInstaller }
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: media)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
            progress(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await installer.install()
    }
    #endif

    public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.onStop?(nil) }
    }

    public nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.onStop?(error) }
    }
}
