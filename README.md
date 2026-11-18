**English** | [简体中文](./README_zh.md)

# Cell

<p align="center">
  <img src="Resources/AppIcon.png" alt="Cell Icon" width="128" height="128" />
</p>

<p align="center">
  <strong>A native macOS app for running Windows games, Windows software, and full virtual machines on Apple Silicon Macs</strong>
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0--beta-orange?style=flat-square" />
  <img alt="Platform" src="https://img.shields.io/badge/macOS-15.0%2B%20(Apple%20Silicon)-blue?style=flat-square" />
  <img alt="Language" src="https://img.shields.io/badge/Swift-6.0%20%2F%20SwiftUI-F05138?style=flat-square" />
  <img alt="License" src="https://img.shields.io/badge/License-Apache--2.0-green?style=flat-square" />
  <img alt="Status" src="https://img.shields.io/badge/status-Beta%20%7C%20Active%20Development-yellow?style=flat-square" />
</p>

> **Beta Notice**
>
> Cell is currently released as a **public beta (v0.3.0-beta)** and is under active development as we continue improving compatibility across Windows apps and games. Runtime behavior can vary depending on your Mac model, macOS version, Wine engine, and game updates. Feel free to report issues, share compatibility logs, or contribute `.cell` plugins via GitHub Issues.
> *(Note: Cell's own UI is currently English-only, while Windows apps and games inside containers have full CJK/Chinese input and font support.)*

---

## Overview

**Cell** is a free, native SwiftUI compatibility-layer and virtual machine manager for Apple Silicon Macs—similar in spirit to CrossOver, Porting Kit, and Whisky, with a different approach:

- **One Container, Every Backend:** Cell wraps Wine, D3DMetal, DXMT, DXVK, MoltenVK, and MSync in a single native app. By default, you only need **one container**—Cell's Autopilot analyzes each executable, runs a headless render probe, and picks the right Wine engine and graphics backend per app (with automatic crash fallback).
- **Extensible `.cell` Plugins:** Compatibility fixes aren't hardcoded. Anyone can package rules, DLLs/mods, shell scripts, and even custom Windows `.exe` tools into a portable `.cell` file to share and import.
- **Flexible App Installation & Migration:** Beyond `.exe` and `.msi` installers, you can **import entire app folders** directly (cloned instantly via APFS) and automatically import existing bottles from CrossOver, Porting Kit, Wineskin, Sikarugir, or Whisky.
- **Accelerated Downloads:** Multi-connection, mirror-assisted downloads with SHA-256 verification, plus parallel pre-fetching of Steam client updates before Steam launches.
- **Built-in Native Utilities:**
  - **Host/DNS Rewriter:** Per-container hostname overrides with IPv4 preference and automatic fallback to the original host—without touching `/etc/hosts`.
  - **Network Assistant:** Detects VPN/TUN apps dropping UDP game traffic, runs STUN NAT tests, configures per-engine macOS firewall rules, and manages NAT-PMP/PCP port mapping.
  - **Native Registry Viewer:** Read and edit Wine registry hives directly in SwiftUI without opening a blank `regedit` window.
  - **Storage & Cleanup:** Per-app disk usage breakdown and safe cleanup of temp files and Steam caches to the Trash.
- **macOS-First Display & Controls:** Automatic `HIGHDPIAWARE` injection for sharp Retina rendering (including CEF/Electron helpers), native-pixel resolution setup for Unity/Unreal, emulated mode switching (`EmulateModeset`) so `Command-Tab`, Mission Control, and trackpad gestures keep working in fullscreen, and a global **`⌘Q` force-quit hotkey** for frozen games (no Accessibility permissions required).
- **Full CJK & Multilingual Support:** Separates display locale from Windows code page (`LC_CTYPE`) to fix `???` input issues in Steam, and maps macOS system fonts (such as PingFang) to Wine's DirectWrite fallback to eliminate missing-glyph boxes.
- **Virtual Machines (Experimental):** Powered by Apple's Virtualization framework, allowing you to import your own OS images to run **Windows on Arm, Android, Linux, and macOS** in portable `.cellvm` bundles.

---

## Virtual Machines (Experimental)

Cell does **not** ship or distribute any operating system images. Bring your own installer image:

| Guest OS | Status | Supported Formats | Notes |
|---|---|---|---|
| **Linux** | ✅ Ready | `.iso` / `.img` / `.raw` (Arm64) | Supports UEFI boot (Ubuntu, Fedora, Debian, Alpine, etc.) or direct Linux kernel boot |
| **macOS** | ✅ Ready | `.ipsw` (Apple Silicon) | Installs using Apple's official restore workflow |
| **Windows (Arm64)** | 🧪 Experimental | `.iso` / `.img` / `.raw` | Boots Windows 11 on Arm ISOs; because Apple's virtual hardware lacks a virtual TPM and some Windows drivers, setup requires workarounds and display support is basic |
| **Android (Arm64)** | 🧪 Experimental | `.iso` / `.img` / `.raw` | Requires an Arm64 Android build that boots via UEFI (such as a VM-targeted AOSP image) |

---

## Quick Start

### System Requirements
- **Chip:** Apple Silicon (M1 / M2 / M3 / M4 or newer) with **Rosetta 2** installed
- **OS:** **macOS 15.0 (Sequoia)** or newer
- **Building from source:** Xcode 16+ (Swift 6)

### Step 1: Install & Verify Rosetta 2
Wine on Apple Silicon requires **Rosetta 2** to translate x86/x86-64 Windows binaries. Check if Rosetta 2 is already installed in Terminal:

```bash
arch -x86_64 /usr/bin/true && echo "Rosetta 2 is installed"
```

If it prompts or returns an error, install Rosetta 2 with:

```bash
softwareupdate --install-rosetta --agree-to-license
```

### Step 2: Install Cell (Beta)
1. Download the latest `Cell.dmg` (or `.zip`) from the **[Releases](../../releases)** page.
2. Open the disk image and drag `Cell.app` into `/Applications`.
3. Because the beta uses local ad-hoc signing (not yet Apple Developer notarized), if macOS blocks the first launch:
   - Run the following command in Terminal:
     ```bash
     xattr -cr /Applications/Cell.app
     ```
   - Or open **System Settings → Privacy & Security** and click **Open Anyway**.

### Step 3: Set Up Apple Game Porting Toolkit (D3DMetal) *(Recommended for DirectX 12)*
Because **D3DMetal** is proprietary Apple software, Cell cannot bundle or download it for you. To enable DirectX 12 games:
1. Sign in with a free Apple ID at [Apple Developer Downloads](https://developer.apple.com/download/all/) and search for **Game Porting Toolkit**.
2. Download the Game Porting Toolkit `.dmg` into your `~/Downloads` folder (keep the `.dmg` there—no need to extract it manually).
3. When you run **Set Up Everything** on first launch, Cell automatically detects the `.dmg` in `~/Downloads` (or any D3DMetal already inside CrossOver / Porting Kit / Whisky on your Mac) and imports it.
4. You can also import it anytime later via **Engines → Import D3DMetal…** in the app, or from the CLI:
   ```bash
   cell import-d3dmetal ~/Downloads/Game_Porting_Toolkit_*.dmg
   ```

### Step 4: First-Run Setup & Adding Apps
1. **One-Click Setup:** Open Cell and click **Set Up Everything** to download and configure Wine, DXMT, your default container, Steam, and Visual C++ runtimes.
2. **Add Windows Software or Games:**
   - **Installers:** Drag and drop any `.exe` or `.msi` onto Cell.
   - **Import Folder (Portable / Pre-installed Apps):** Click **+ → Add App Folder…** (or drag a whole game/app folder into a container) to clone it into `C:\Games\` and auto-detect the main executable.
   - **Steam:** Install Steam with one click inside the container; installed games and artwork sync automatically to Home.
   - **Migrate Existing Bottles:** Import CrossOver, Porting Kit, or Whisky bottles during setup, or drop an existing `steam.exe` onto Cell.

---

## Using & Building `.cell` Plugins

Cell's compatibility database and user extensions share the same **`.cell` plugin package** format.

### 1. Overview
- A `.cell` file is a standard **ZIP archive** with `plugin.json` at its root.
- It can bundle nested folders and arbitrary assets: **shell scripts (`.zsh`/`.sh`), Windows executables (`.exe`/`.msi`), DLLs, mods, and icons**.
- Cell extracts packages safely (blocking symlinks and path traversal). **Scripts and `.exe` actions are disabled by default** until you explicitly enable **Allow scripts and programs** on the plugin's page (modifying package contents resets trust automatically).

### 2. Using Existing `.cell` Plugins
- **Import:** Double-click a `.cell` file in Finder, drag it onto Cell, or use **Plugin → Import**.
- **Scope:** Plugins apply to all containers by default, or you can switch a plugin to **Only the layers I choose** / toggle it per container under the container's **Plugins** tab.
- **Options & Actions:** Adjust plugin-provided toggles/choices or run bundled tools directly from the plugin detail view.
- **Reference Example:** Check out `Examples/Sky Support.cell` (full source in [`Examples/Sky Support/`](Examples/Sky%20Support)), which demonstrates icons, user options, key remapping, a `preLaunch` shell hook, and a custom Windows `.exe` diagnostic tool.

### 3. Creating Your Own `.cell` Plugin

#### Option A: Using the Built-in GUI Editor
1. Go to **Plugin** in the sidebar and click **+ (Create)** to set a name, unique package ID (e.g., `com.yourname.mygame`), executable name, or Steam App ID.
2. Select the plugin and click **Edit Plugin…** to edit `plugin.json`, add interactive controls via **Options → Add Option…**, set an icon via **Set Picture…**, and bundle `.exe`/`.dll`/script/mod files via **Add Files or Folders…**.
3. Click **Export .cell** in the toolbar to save a shareable `.cell` package.

#### Option B: Using a Directory + the `cell` CLI
1. Create a folder structure like this:
   ```text
   my-plugin/
   ├── plugin.json           # Required: manifest, match rules, fixes, and actions
   ├── icon.png              # Optional: plugin icon
   ├── files/                # Optional: DLLs, mods, or configs copied into the game folder
   │   └── dinput8.dll
   ├── scripts/              # Optional: macOS-side shell hooks or helper scripts
   │   ├── before.zsh
   │   └── check.zsh
   └── tools/                # Optional: custom Windows .exe/.msi tools run inside Wine
       └── ModSetup.exe
   ```
2. Scaffold, validate, and pack it with `cell`:
   ```bash
   # Generate a starter plugin
   cell plugin new "My Game" --id com.example.mygame --exe MyGame.exe --steam-app-id 123456

   # Validate a plugin folder or .cell package
   cell plugin validate ./my-plugin

   # Pack a folder into a single .cell file
   cell plugin pack ./my-plugin ./MyGame.cell

   # Import for testing or export an installed plugin
   cell plugin import ./MyGame.cell
   cell plugin export com.example.mygame ./MyGame-out.cell
   ```

### 4. Complete `plugin.json` Example

```json
{
  "schemaVersion": 1,
  "id": "com.example.my-game-kit",
  "name": "My Game Enhancer",
  "version": "1.0.0",
  "author": "YourName",
  "summary": "Fixes rendering and input issues and bundles a mod installer and DNS check.",
  "useWhen": "Enable if the game has a black screen, FPS issues, or needs one-click mod setup.",
  "icon": "icon.png",
  "updateURL": "https://example.com/releases/MyGame.cell",
  "scope": { "containers": "all", "platforms": ["windows"] },
  "match": {
    "any": [
      { "steamAppID": "123456" },
      { "executable": "MyGame*.exe" }
    ]
  },
  "options": [
    {
      "id": "fps",
      "title": "Frame-rate cap",
      "type": "choice",
      "choices": ["60", "120", "144"],
      "default": "60"
    },
    {
      "id": "arrowToWASD",
      "title": "Map arrow keys to WASD",
      "type": "toggle",
      "default": "false"
    }
  ],
  "fixes": {
    "graphics": { "prefer": ["dxmt", "d3dmetal"], "avoid": ["wined3d"] },
    "arguments": {
      "append": ["-fps={option.fps}"],
      "whenBackend": { "dxmt": ["-force-d3d11"] }
    },
    "environment": {
      "set": { "MY_CUSTOM_FLAG": "1" }
    },
    "dllOverrides": { "dinput8": "native,builtin" },
    "registry": [
      { "key": "DirectInput", "name": "MouseWarpOverride", "type": "string", "value": "force", "scope": "app" }
    ],
    "wine": {
      "windowsVersion": "win10",
      "scrollMode": "notched",
      "highResolution": true
    },
    "steam": { "overlay": "disabled" },
    "ini": [
      {
        "file": "{localAppData}/{unrealProject}/Saved/Config/Windows/GameUserSettings.ini",
        "section": "/Script/Engine.GameUserSettings",
        "set": { "FullscreenMode": "1", "ResolutionSizeX": "{screenWidth}", "ResolutionSizeY": "{screenHeight}" },
        "create": true
      }
    ],
    "files": [
      { "from": "files/dinput8.dll", "to": "{gameDir}/dinput8.dll", "overwrite": false }
    ],
    "devices": {
      "serialPorts": { "COM3": "/dev/cu.usbserial-*" }
    },
    "network": {
      "ports": [{ "proto": "udp", "port": 27015 }]
    },
    "notes": ["Enable 'Allow scripts and programs' on this plugin page before running bundled tools."]
  },
  "optionFixes": {
    "arrowToWASD": {
      "wine": {
        "keyMappings": { "Up": "W", "Left": "A", "Down": "S", "Right": "D" }
      }
    }
  },
  "scripts": {
    "preLaunch": "scripts/before.zsh",
    "postExit": "scripts/after.zsh"
  },
  "actions": [
    { "id": "installMod", "title": "Run Mod Installer (.exe)", "runner": "wine", "file": "tools/ModSetup.exe" },
    { "id": "checkEnv", "title": "Check Environment (Shell)", "runner": "shell", "file": "scripts/check.zsh", "arguments": ["--manual"] }
  ],
  "diagnostics": [
    {
      "id": "mygame.vcrun",
      "log": "wine",
      "pattern": "MSVCP140\\.dll.*not found",
      "severity": "error",
      "title": "Visual C++ runtime missing",
      "advice": "Install Visual C++ Runtimes in Container Settings."
    }
  ]
}
```

#### Quick Reference for Plugin Authors
- **Path & Value Templates:** `{prefix}`, `{driveC}`, `{gameDir}`, `{exeDir}`, `{userProfile}`, `{appData}`, `{localAppData}`, `{localLow}`, `{documents}`, `{savedGames}`, `{steamDir}`, `{pluginDir}`, `{unrealProject}`, `{unityCompany}`, `{unityProduct}`, `{unityPlayerLog}`, `{screenWidth}`, `{screenHeight}`, and `{option.<id>}`.
- **Script Environment Variables:** `preLaunch`/`postExit` hooks (run with `/bin/zsh`) and shell actions receive `CELL_PREFIX`, `CELL_GAME_DIR`, `CELL_APP_NAME`, `CELL_BACKEND`, `CELL_PLUGIN_DIR`, `CELL_WINE_LOADER`, and `CELL_PLUGIN_OPTION_<optionId>`.
- **Full Specification:** See [`Docs/PLUGINS.md`](Docs/PLUGINS.md) for all match rules (`engine`, `engineVersion`, `graphicsAPI`, `fileExists`, `architecture`, etc.) and advanced capabilities.

---

## Command-Line Interface (`cell`)

Cell bundles a CLI companion at `Cell.app/Contents/Helpers/cell`:

```bash
# Run, add, and analyze apps
cell run <setup.exe|.msi> [--container <name>]    # Run an installer or executable
cell add <program.exe|folder> [--container <name>] # Add an executable or import an app folder
cell launch --app <id> [--backend d3dmetal|dxmt|dxvk|wined3d]
cell analyze <game.exe>                            # Inspect engine, graphics API, DPI awareness & Autopilot pick
cell plan --app <id>                               # Preview the full launch plan and environment

# Containers, engines, and migration
cell list | containers | engines
cell check-engines [--again]                       # Run headless render probes across engine pairs
cell import-engine <path>                          # Import a Wine engine
cell import-d3dmetal <path>                        # Import D3DMetal (GPTK .dmg or folder)
cell import-dxmt <path>                            # Import DXMT
cell bottles                                       # List CrossOver / Porting Kit / Whisky bottles on this Mac
cell import-bottle <name|path>                     # Migrate an existing bottle

# Plugin management (.cell)
cell plugin list | validate <path> | import <path> | export <id> <file.cell>
cell plugin new <name> [--id ...] [--exe ...] [--steam-app-id ...]
cell plugin pack <source-folder> <file.cell>

# Virtual machines (.cellvm)
cell vm list
cell vm create --name <n> --guest linux|macos|windows|android [--installer <iso|ipsw>]
cell vm start <name|id> [--seconds 30]
cell vm delete <name|id>

# Network diagnostics
cell nat-test                                      # Test UDP reachability across VPN/proxy and NAT type
```

---

## Building from Source & Project Layout

### Build & Test
```bash
git clone https://github.com/EgoGold/Cell.git
cd Cell

# Build the release app bundle (compiles native helpers, packs built-in .cell plugins -> build/Cell.app)
./Scripts/build-app.sh
open build/Cell.app

# Run unit tests
swift test
```

### Repository Structure
```text
Sources/
├── CellCore/        Core engine (containers, runtimes, PE/engine analysis, Autopilot, plugins, VMs, network, diagnostics)
├── CellUI/          Native SwiftUI views and design tokens (Theme.swift)
├── Cell/            macOS app entry point
├── CellCLI/         `cell` CLI tool and fast shortcut launcher
└── CellArchive/     libarchive wrapper for safe .cell package extraction
Plugins/             Built-in compatibility database (20 .cell plugin sources)
Examples/            Developer plugin example (Sky Support.cell + full C/Shell source)
Tools/               Native & Windows helpers (engine-probe, game-hotkey, dock-name, webview-bridge, steamwebhelper-wrapper, PE linker)
Resources/           App icons, Info.plist, and virtualization entitlements (Cell.entitlements)
Scripts/             Release build script (build-app.sh)
Docs/                Plugin authoring guide (PLUGINS.md)
Tests/               CellCore unit tests
```

### Local Data Paths
All containers, engines, plugins, icons, and virtual machines are stored locally in:
- Data: `~/Library/Application Support/Cell`
- Logs: `~/Library/Logs/Cell`

---

## Current Status & Known Limitations

Cell is in **active beta development**, and we are continuously expanding software and game compatibility:

- **Active Compatibility Work:** Certain DirectX 12 titles, kernel-level anti-cheat games, media codecs, and focus-switching edge cases are still being investigated and improved.
- **Known Boundaries:**
  - Kernel-mode anti-cheat drivers (e.g., certain EAC / BattlEye configurations) cannot run under Wine on macOS; Cell warns you upfront instead of failing silently.
  - Wine on macOS does not support non-serial USB or Bluetooth passthrough (serial/COM devices are supported via plugin `devices.serialPorts`).
  - Windows on Arm and Android virtual machines remain experimental due to Apple Virtualization hardware constraints (no virtual TPM and limited guest drivers).

---

## License & Acknowledgments

- Licensed under the **[Apache License 2.0](LICENSE)**.
- **No Proprietary Assets Distributed:** Cell does not include or distribute Apple **D3DMetal** (Game Porting Toolkit) or any operating system installer images (Windows, macOS, Linux, or Android). Users provide and import those components locally.
- Thanks to **Wine**, **DXMT**, **DXVK**, **MoltenVK**, **Gcenx**, and the broader macOS compatibility-layer open-source community.
