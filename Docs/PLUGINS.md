# Writing Cell plugins

A plugin fixes one game, an engine family (all Unity games) or a whole class of programs (DirectX 9
games). Cell's built-in compatibility database is made of the same plugins you can write.

- A plugin is a single `.cell` package with `plugin.json` at the root. It uses ZIP and can contain nested folders and arbitrary data files such as MOD files, DLLs, EXEs and APKs.
- Use **Plugins → Import**, drop a package onto Cell, or open it in Finder. Cell also imports older ZIPs and plugin folders.
- Use **Create** and **Edit Plugin** to add files, options and a picture. **Export .cell** saves a portable copy.
- `cell plugin new "My Game" --id com.example.mygame --exe MyGame.exe` creates a starter.
- `cell plugin validate path/to/My.cell` checks a package. `cell plugin pack source-folder My.cell` packages an authoring folder.
- A user plugin with the same `id` as a built-in one replaces it, so you can patch fixes locally.

## Minimal example

```json
{
  "schemaVersion": 1,
  "id": "com.example.my-game",
  "name": "My Game",
  "version": "1.0.0",
  "author": "You",
  "summary": "One sentence shown on the game's page.",
  "match": { "any": [ { "steamAppID": "123456" }, { "executable": "MyGame.exe" } ] },
  "fixes": {
    "graphics": { "prefer": ["dxmt", "d3dmetal"] },
    "arguments": { "append": ["-window-mode", "borderless"], "whenBackend": { "dxmt": ["-force-d3d11"] } },
    "notes": ["Why this works, for the person reading the game page."]
  }
}
```

## Top level

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1` |
| `id` | yes | Unique id: letters, digits, `.`, `-`, `_` |
| `name`, `version` | yes | Shown in Cell |
| `author`, `summary`, `homepage` | no | Shown in Cell |
| `icon` | no | Relative path to a package image |
| `updateURL` | no | HTTPS link to the latest package with this ID |
| `priority` | no | Default `0`. Higher plugins are applied later and win conflicts |
| `match` | yes | When the plugin applies |
| `fixes` | no | What it changes |
| `diagnostics` | no | Log patterns that explain problems after a launch |
| `scripts` | no | Shell scripts (run only after the user trusts the plugin) |
| `scope` | no | Where the plugin applies when it is added (below) |
| `useWhen` | no | When someone should use it: the problem it solves, in one sentence. Shown first on its page |
| `options`, `optionFixes` | no | Settings people can adjust, and fixes that follow them (below) |

### Scope

```json
"scope": { "containers": "all", "platforms": ["windows"] }
```

- `containers`: `"all"` (default) — every translation layer; `"chosen"` — off until the user turns it on in a
  layer (its Plugins tab). Added from a layer's Plugins tab, a plugin applies to that layer only.
- `platforms`: kinds of layers it can apply to (`windows`, `linux`). Missing: any.
- Users can always change this: the Plugins page has "Every translation layer / Only the layers I choose"
  with a switch per layer, and each layer's Plugins tab switches plugins off there only.
- Plugin folders end in `.cell` (`.cellplug`, `.cellplugin` and `.chamberplugin` from earlier versions still load, and installed ones are renamed).

## Matching

```json
"match": {
  "any":  [ rule, rule ],   // at least one must match
  "all":  [ rule ],         // every rule must match
  "none": [ rule ]          // no rule may match
}
```

Every field you set in a rule must match:

| Rule field | Example | Notes |
|---|---|---|
| `steamAppID` | `"3527290"` | |
| `executable` | `"PEAK.exe"`, `"*-Win64-Shipping.exe"` | Glob, case-insensitive. Matches the launched exe or the analysed one (Unreal stubs) |
| `pathContains` | `"steamapps/common/Hades"` | |
| `engine` | `"unity"` | `unity`, `unreal`, `godot`, `gameMaker`, `source`, `source2`, `rpgMaker`, `renpy`, `xna`, `fna`, `monoGame`, `electron`, `cef`, `java` |
| `engineVersion` | `">=2021"`, `"<6000.3"`, `"5.*"`, `">=2019 <2023"` | Unity/Unreal version from the binaries |
| `graphicsAPI` | `"d3d12"` | `ddraw`, `d3d8`, `d3d9`, `d3d10`, `d3d11`, `d3d12`, `opengl`, `vulkan` |
| `productName`, `companyName` | `"Escape the Backrooms*"` | From the exe's version information (glob) |
| `fileExists` | `"EasyAntiCheat"` | Relative to the game folder |
| `architecture` | `"x86"` | `x86` or `x64` |
| `appKind` | `"steamClient"` | `windowsExecutable`, `steamClient`, `steamGame` |

More specific rules (Steam app ID / exe) override generic ones (engine / API) automatically.

## Fixes

```json
"fixes": {
  "graphics":    { "prefer": ["d3dmetal"], "avoid": ["dxvk"] },
  "arguments":   { "append": ["-nosplash"], "whenBackend": { "dxmt": ["-dx11"] } },
  "environment": { "set": { "KEY": "value" }, "whenBackend": { "dxmt": { "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;" } } },
  "dllOverrides": { "xaudio2_7": "native,builtin", "gameoverlayrenderer64": "" },
  "registry": [
    { "key": "HKCU\\Software\\MyStudio\\MyGame", "name": "Fullscreen", "type": "dword", "value": "0" },
    { "key": "DirectInput", "name": "MouseWarpOverride", "type": "string", "value": "force", "scope": "app" }
  ],
  "wine":    { "windowsVersion": "win10", "scrollMode": "notched", "captureDisplays": true, "highResolution": true, "mouseWarp": "force" },
  "steam":   { "overlay": "disabled", "clientArguments": ["-no-browser"] },
  "ini": [
    { "file": "{localAppData}/{unrealProject}/Saved/Config/Windows/GameUserSettings.ini",
      "section": "/Script/Engine.GameUserSettings", "set": { "FullscreenMode": "1", "ResolutionSizeX": "{screenWidth}" }, "create": true }
  ],
  "files":   [ { "from": "files/dinput8.dll", "to": "{gameDir}/dinput8.dll", "overwrite": false } ],
  "network": { "ports": [ { "proto": "udp", "port": 27015 } ] },
  "notes":   ["Shown on the game's page."]
}
```

- **graphics** — backends: `d3dmetal`, `dxmt`, `dxvk`, `wined3d`. `prefer` is an ordered list; `avoid` moves
  a backend to the very end (it stays as a last resort).
- **registry** `type`: `string`, `expand`, `multi` (use `values`), `dword`, `qword` (decimal or `0x…`),
  `binary` (hex bytes), `delete` (a value), `deleteKey`. With `"scope": "app"` the key is relative to
  `HKCU\Software\Wine\AppDefaults\<game.exe>\`, so it only affects this game, even when Steam starts it.
- **wine** — `scrollMode`: `automatic`, `smooth`, `notched`; `mouseWarp`: `enable`, `disable`, `force`;
  `windowsVersion`: `win11`, `win10`, `win81`, `win8`, `win7`, `winxp`.
- **steam.overlay** — `enabled` / `disabled` (blocks the overlay DLL for this game only).
- **steam.launchArguments** — arguments given to Steam's game or launcher when launched from Cell.
  These stay out of direct game launches and do not change Steam Library's saved launch options.
- **devices.serialPorts** — Windows serial ports and the Mac devices behind them, e.g.
  `"devices": { "serialPorts": { "COM3": "/dev/cu.usbserial-*" } }` (the first match is used). Microcontroller tools,
  PLC and lab software and old device programmers talk to them as COM ports.

### Options people can adjust

```json
"options": [
  { "id": "fps", "title": "Frame-rate cap", "type": "choice", "choices": ["30", "60", "120"], "default": "60" },
  { "id": "skipIntro", "title": "Skip intro videos", "type": "toggle", "default": "false",
    "help": "Starts straight at the menu." }
],
"fixes": { "arguments": { "append": ["-fps={option.fps}"] } },
"optionFixes": { "skipIntro=true": { "arguments": { "append": ["-nointro"] } } }
```

- `type`: `toggle`, `choice` (needs `choices`), `number`, `text`. The plugin's page shows the matching controls.
- `{option.<id>}` is replaced in arguments, environment values, registry values, INI values, device paths and notes.
- `optionFixes` keys are `id=value`, or just `id` for a toggle that is on; those fixes apply while it matches.

### Talking to the Mac and other apps

Windows programs in Cell reach the Mac the ways Wine provides: network ports on `127.0.0.1` (a Mac app or a
plugin's helper can listen there), files through the `Z:` drive (`Z:\Users\you\…`), Mac programs and URLs through
`start /unix /path/to/program` and `winebrowser`, and serial devices through `devices.serialPorts`. A plugin's
`scripts` (`preLaunch`, `postExit`) run on the Mac side once the person trusts the plugin, e.g. to start a bridge
before the program and stop it afterwards. USB devices other than serial adapters, and Bluetooth, aren't reachable:
Wine on macOS has no driver for them.

### Path and value templates

`ini`, `files`, argument values and INI values can use:

`{prefix}` `{driveC}` `{gameDir}` `{exeDir}` `{userProfile}` `{appData}` `{localAppData}` `{localLow}`
`{documents}` `{savedGames}` `{steamDir}` `{pluginDir}` `{unrealProject}` `{unityCompany}` `{unityProduct}`
`{unityPlayerLog}` `{screenWidth}` `{screenHeight}`

Writes are only allowed inside the container and the game's folder (paths that resolve elsewhere,
including through symlinks such as Documents → your Mac's Documents, are skipped).

## Diagnostics

After every launch Cell scans logs and shows matching findings on the game's page.

```json
"diagnostics": [
  { "id": "mygame.vcrun", "log": "wine", "pattern": "MSVCP140\\.dll.*not found",
    "severity": "error", "title": "Visual C++ runtime missing", "advice": "Container ▸ Tools ▸ Install Visual C++ Runtimes." },
  { "id": "mygame.unity", "log": "{unityPlayerLog}", "pattern": "Failed to create D3D11 device", "severity": "warning", "title": "…" }
]
```

`log` is `wine` (the launch log) or a path template. `pattern` is a regular expression.

## Scripts

```json
"scripts": { "preLaunch": "scripts/before.sh", "postExit": "scripts/after.sh" }
```

Turn on **Allow scripts and programs** on the plugin page to run hooks or actions. Installing changed package bytes clears that permission. Hooks run with `/bin/zsh` on launches started by Cell. They receive `CELL_PREFIX`, `CELL_GAME_DIR`, `CELL_APP_NAME`, `CELL_BACKEND`, `CELL_PLUGIN_DIR`, `CELL_WINE_LOADER`, and the Wine environment. A plugin option such as `installMod` appears as `CELL_PLUGIN_OPTION_installMod`.

To put a button in the control panel, declare an action. A Wine action runs a bundled Windows EXE or MSI in the chosen layer. A shell action can call tools the user already has, including tools that consume other payloads.

```json
"actions": [
  { "id": "install", "title": "Install Mod", "runner": "wine", "file": "tools/Setup.exe" },
  { "id": "check", "title": "Check Installation", "runner": "shell", "file": "scripts/check.zsh" }
]
```

For keyboard remapping, add `"keyMappings": {"Left": "A", "Right": "D"}` under `fixes.wine` or under an option's Wine fixes. Maps apply to the matching Windows program at launch. They accept letters, digits, direction keys, F1–F12, Enter, Tab, Space, Backspace and Escape.

## Sharing

Export the `.cell` file and share it. Keep the same package ID for subsequent releases. Importing the same or a newer version installs it over the existing one. Cell requests confirmation before installing an older version. The reload button also fetches updates from the declared addresses and checks each downloaded package ID.

Restore Default Config resets the plugin's options, layer selection, switch and script permission. Package files and changes already applied by a plugin stay where they are.

The standalone Sky example in `Examples/Sky Support.cell` contains a shell hook, a runnable Windows program, source, a picture, options and key mappings. Import it like any other package.
