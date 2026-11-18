<p align="right">
  <a href="README.md">English</a> | <strong>简体中文</strong>
</p>

# Cell

<p align="center">
  <img src="Resources/AppIcon.png" alt="Cell Icon" width="128" height="128" />
</p>

<p align="center">
  <strong>在 Apple Silicon Mac 上无缝运行 Windows 游戏、软件，以及完整虚拟机系统的原生应用</strong>
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0--beta-orange?style=flat-square" />
  <img alt="Platform" src="https://img.shields.io/badge/macOS-15.0%2B%20(Apple%20Silicon)-blue?style=flat-square" />
  <img alt="Language" src="https://img.shields.io/badge/Swift-6.0%20%2F%20SwiftUI-F05138?style=flat-square" />
  <img alt="License" src="https://img.shields.io/badge/License-Apache--2.0-green?style=flat-square" />
  <img alt="Status" src="https://img.shields.io/badge/status-Beta%20%7C%20Active%20Development-yellow?style=flat-square" />
</p>

> **测试版说明**
>
> Cell 目前正以 **测试版（v0.3.0-beta）** 形式公开发布，项目仍在持续开发、改进与适配更多 Windows 软件和游戏。运行表现可能受 Mac 机型、macOS 版本、Wine 引擎及游戏更新影响。欢迎通过 GitHub Issues 反馈兼容性日志、提交 Bug 或分享你的 `.cell` 插件。当前版本 Cell 界面仅支持英文，容器内软件完整支持中文。

---

## 简介

**Cell** 是一款面向 Apple Silicon Mac 的免费、原生 SwiftUI 兼容层与虚拟机管理工具：

- **一个容器**：将 Wine、D3DMetal、DXMT、DXVK、MoltenVK 与 MSync 统一封装在单一原生应用中，默认只需一个容器，即可由 Autopilot 自动为每个软件匹配最佳引擎与图形后端。
- **插件（`.cell`）**：兼容修复不再写死在代码中，任何人都可以将配置规则、DLL/MOD、Shell 脚本甚至自定义 `.exe` 工具打包为单个 `.cell` 文件分享与导入。
- **安装与导入**：除 `.exe` / `.msi` 外，可直接导入软件文件夹，可识别设备上其它管理工具的现有容器。
- **下载**：支持多线程并行与镜像加速下载（SHA-256 校验），启动 Steam 前预先并发下载其客户端更新包，解决 Steam 单线程更新缓慢问题。
- **原生工具套件**：
  - **Host/DNS 重写器**：无需修改系统 `/etc/hosts`，按容器配置域名重写、IPv4 优先与失败自动回退原域名。
  - **网络助手**：自动识别 VPN/TUN 代理是否丢弃游戏 UDP 流量，内置国内外 STUN NAT 类型检测、逐引擎 macOS 防火墙放行与 NAT-PMP/PCP 端口映射。
  - **注册表**：无需打开白屏 `regedit`，以 Cell 内置注册表浏览器直接读写 Wine Hive 文件。
  - **空间清理**：按应用统计磁盘占用，支持安全清理临时文件与 Steam 缓存至废纸篓。
- **画面与操作**：自动为未声明 DPI 感知的游戏及 CEF/Electron 辅助进程注入 `HIGHDPIAWARE`；自动调整 Unity / Unreal 至显示器原生像素分辨率，并启用显示模式模拟，全屏时 Command-Tab、调度中心与触控板手势依然可用。全局 `⌘Q` 立即退出游戏，即使游戏已卡死。
- **多语种支持**：分离界面语言与代码页（解决了中文输入法在 Steam 中显示 `???` 的问题）；为 DirectWrite 自动建立中/日/韩/阿/印地语等 macOS 系统字体映射（如苹方 PingFang），消除游戏内方块字。
- **虚拟机（实验性）**：除 Windows 转译层，基于 Apple Virtualization 框架支持导入系统镜像运行 Windows on Arm、Android、Linux 与 macOS。

---

## 虚拟机（实验性）

Cell **不内置也不分发任何操作系统镜像**，请自行准备并导入安装镜像：

| 目标系统 | 支持状态 | 支持的镜像格式 | 说明 |
|---|---|---|---|
| **Linux** | ✅ 可用 | `.iso` / `.img` / `.raw`（Arm64） | 支持 UEFI 启动（Ubuntu、Fedora、Debian、Alpine 等）或直接内核引导 |
| **macOS** | ✅ 可用 | `.ipsw`（Apple Silicon） | 调用 Apple 官方恢复流程安装 |
| **Windows (Arm64)** | 🧪 实验性 | `.iso` / `.img` / `.raw` | 支持导入 Windows 11 on Arm 镜像启动；因 Apple 虚拟硬件缺少虚拟 TPM 及部分网卡/显卡驱动，安装阶段需绕过检查且目前仅提供基础显示 |
| **Android (Arm64)** | 🧪 实验性 | `.iso` / `.img` / `.raw` | 需使用支持 UEFI 启动的 Arm64 Android 镜像（如面向虚拟机的 AOSP 镜像） |

---

## 快速上手

### 系统要求
- **芯片**：Apple Silicon（M1 / M2 / M3 / M4 及以上），需安装 **Rosetta 2**
- **系统**：**macOS 15.0 (Sequoia)** 或更高版本
- **从源码构建**：Xcode 16+（Swift 6）

### 第一步：安装并检查 Rosetta 2
Wine 在 Apple Silicon Mac 上运行 x86/x86-64 Windows 程序需要依赖 **Rosetta 2**。打开终端运行以下命令检查是否已安装：

```bash
arch -x86_64 /usr/bin/true && echo "Rosetta 2 已安装"
```

如果提示未安装或报错，执行以下命令即可一键安装：

```bash
softwareupdate --install-rosetta --agree-to-license
```

### 第二步：安装测试版（Beta）
1. 前往本仓库 **[Releases](../../releases)** 页面下载最新的 `Cell.dmg`（或 `.zip`）。
2. 打开镜像后将 `Cell.app` 拖入 `/Applications` 文件夹。
3. 由于当前测试版采用本地 Ad-hoc 签名，尚未进行 Apple Developer 公证，首次打开如遇到 macOS 安全提示，可在终端运行：
   ```bash
   xattr -cr /Applications/Cell.app
   ```
   或在“系统设置 → 隐私与安全性”中点击“仍要打开”。

### 第三步：准备 Apple Game Porting Toolkit（D3DMetal）*（玩 DX12 游戏推荐）*
由于 **D3DMetal** 属于 Apple 专有组件，Cell 不能直接内置或从网上下载。如需运行 DirectX 12 游戏，请按以下步骤获取：
1. 使用免费 Apple ID 登录 [Apple Developer Downloads](https://developer.apple.com/download/all/)，搜索 **Game Porting Toolkit**。
2. 将下载好的 Game Porting Toolkit `.dmg` 文件直接留在你的 **`~/Downloads`（下载）** 目录中（无需手动解压或挂载）。
3. 首次启动 Cell 点击 **Set Up Everything** 时，Cell 会自动扫描 `~/Downloads` 下的 GPTK `.dmg`（或本机 CrossOver / Porting Kit / Whisky 已有引擎中的 D3DMetal）并完成导入。
4. 之后也可以随时在界面 **Engines → Import D3DMetal…** 中手动导入，或使用命令行：
   ```bash
   cell import-d3dmetal ~/Downloads/Game_Porting_Toolkit_*.dmg
   ```

### 第四步：首次配置与运行软件
1. **一键配置**：首次打开 Cell 点击 **Set Up Everything**，等待 Wine、DXMT、默认容器、Steam 与基础运行库自动配置完成。
2. **安装或运行 Windows 软件 / 游戏**：
   - **安装包**：直接将 `.exe` / `.msi` 拖入 Cell。
   - **导入文件夹**：点击顶部 **+ → Add App Folder…** 或将整个软件文件夹拖入容器，即可自动克隆至 `C:\Games\` 并识别主程序。
   - **Steam 游戏**：在容器内一键安装 Steam，已安装游戏与封面会自动同步至首页。
   - **导入旧容器**：在设置或首次引导时导入 CrossOver / Porting Kit / Whisky 容器，或直接把旧容器的 `steam.exe` 拖进 Cell。

---

## 使用与构建 `.cell` 插件

Cell 的核心扩展机制是 **`.cell` 插件包**——它既是 Cell 内置兼容数据库的格式，也是你为任何软件/游戏编写修复补丁、自动化脚本、甚至打包自定义 `.exe` 工具的标准容器。

### 1. 概述
- 一个以 `.cell` 为后缀的标准 **ZIP 压缩包**，根目录必须包含 `plugin.json`。
- 包内可包含任意层级的子文件夹与数据文件：**Shell 脚本（`.zsh`/`.sh`）、Windows 可执行程序（`.exe`/`.msi`）、DLL 补丁、MOD 文件、图标图片**等。
- Cell 使用安全的底层解包机制，自动拦截符号链接与越权路径写入，且**所有脚本和 `.exe` 动作默认禁用**，只有当用户手动在插件页开启 **Allow scripts and programs** 后才会运行；若插件包内容发生变化，权限会自动重置。

### 2. 如何使用现有的 `.cell` 插件
- **导入**：双击 Finder 中的 `.cell` 文件、直接将其拖拽到 Cell 窗口，或在 **Plugin → Import** 中选择导入。
- **控制生效范围**：默认对所有容器生效，也可在插件详情页切换为 **Only the layers I choose**，或在单个容器的 **Plugins** 标签页中单独开关。
- **运行内置动作 / 调整选项**：若插件声明了可视化选项（如帧率限制、跳过片头、按键映射）或内置脚本/工具按钮，可在插件详情页直接调节或点击执行（需先开启脚本信任开关）。
- **参考示例**：仓库中自带了 `Examples/Sky Support.cell`（源码见 [`Examples/Sky Support/`](Examples/Sky%20Support)），完整演示了图标、选项、方向键映射、Pre-launch Shell 钩子以及打包运行自定义 Windows `.exe` 程序的做法。

### 3. 两种方式创建与构建自己的 `.cell`

#### 方式 A：直接在 Cell 图形界面创建
1. 打开侧边栏 **Plugin**，点击右上角 **+（Create）**，填写插件名称、唯一包 ID（如 `com.yourname.mygame`）、匹配的 `.exe` 名称或 Steam AppID。
2. 选中新建的插件，点击 **Edit Plugin…**：
   - 在编辑器中修改 `plugin.json`；
   - 点击 **Options → Add Option…** 可视化添加开关/下拉选择/文本/数字配置项；
   - 点击 **Set Picture…** 为插件设置封面/图标；
   - 点击 **Add Files or Folders…** 将你的 `.exe`、`.dll`、Shell 脚本或 MOD 文件夹直接加入 `.cell` 包中。
3. 保存后，点击工具栏 **Export .cell** 即可导出单文件 `.cell` 安装包分享给他人。

#### 方式 B：通过目录 + CLI 命令行构建
1. 准备如下插件目录结构：
   ```text
   my-plugin/
   ├── plugin.json           # 必需：插件清单、匹配规则、修复项与动作声明
   ├── icon.png              # 可选：插件图标
   ├── files/                # 可选：自动复制到游戏目录的 DLL / MOD / 配置文件
   │   └── dinput8.dll
   ├── scripts/              # 可选：macOS 侧 Shell Hook 或工具脚本
   │   ├── before.zsh
   │   └── check.zsh
   └── tools/                # 可选：在 Wine 容器中运行的自定义 Windows 工具或安装器
       └── ModSetup.exe
   ```
2. 使用 Cell 自带的命令行工具创建模板、校验并打包为 `.cell`：
   ```bash
   # 生成插件脚手架
   cell plugin new "My Game" --id com.example.mygame --exe MyGame.exe --steam-app-id 123456

   # 校验目录或 .cell 包的格式与字段是否合法
   cell plugin validate ./my-plugin

   # 将开发目录打包为单文件 .cell
   cell plugin pack ./my-plugin ./MyGame.cell

   # 安装测试或导出已安装插件
   cell plugin import ./MyGame.cell
   cell plugin export com.example.mygame ./MyGame-out.cell
   ```

### 4. `plugin.json` 核心字段与示例

下面是一个包含**匹配规则、图形/Wine 修复、交互选项、按键映射、Shell Hook 以及内置 `.exe` 工具按钮**的完整示例：

```json
{
  "schemaVersion": 1,
  "id": "com.example.my-game-kit",
  "name": "My Game Enhancer",
  "version": "1.0.0",
  "author": "YourName",
  "summary": "修复画面与输入问题，并内置一键 Mod 安装工具与网络诊断脚本。",
  "useWhen": "当游戏黑屏、帧率异常或需要一键安装补丁时启用。",
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
      "title": "帧率上限",
      "type": "choice",
      "choices": ["60", "120", "144"],
      "default": "60"
    },
    {
      "id": "arrowToWASD",
      "title": "将方向键映射为 WASD",
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
    "notes": ["首次使用请先在插件详情页开启「Allow scripts and programs」以运行内置工具。"]
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
    { "id": "installMod", "title": "运行 Mod 安装器 (.exe)", "runner": "wine", "file": "tools/ModSetup.exe" },
    { "id": "checkEnv", "title": "检查运行环境 (Shell)", "runner": "shell", "file": "scripts/check.zsh", "arguments": ["--manual"] }
  ],
  "diagnostics": [
    {
      "id": "mygame.vcrun",
      "log": "wine",
      "pattern": "MSVCP140\\.dll.*not found",
      "severity": "error",
      "title": "缺少 Visual C++ 运行库",
      "advice": "请在容器设置中安装 Visual C++ 运行库。"
    }
  ]
}
```

#### 插件编写常用
- **内置路径/变量模板**：`{prefix}`、`{driveC}`、`{gameDir}`、`{exeDir}`、`{userProfile}`、`{appData}`、`{localAppData}`、`{localLow}`、`{documents}`、`{savedGames}`、`{steamDir}`、`{pluginDir}`、`{unrealProject}`、`{unityCompany}`、`{unityProduct}`、`{unityPlayerLog}`、`{screenWidth}`、`{screenHeight}`，以及动态选项 `{option.<id>}`。
- **脚本可读取的环境变量**：`preLaunch`/`postExit`（由 `/bin/zsh` 执行）及 Shell Action 可直接读取 `CELL_PREFIX`、`CELL_GAME_DIR`、`CELL_APP_NAME`、`CELL_BACKEND`、`CELL_PLUGIN_DIR`、`CELL_WINE_LOADER`，以及用户勾选的选项 `CELL_PLUGIN_OPTION_<optionId>`。
- **完整规范**：更多匹配条件（`engine`、`engineVersion`、`graphicsAPI`、`fileExists`、`architecture` 等）与高级用法请参阅 [`Docs/PLUGINS.md`](Docs/PLUGINS.md)。

---

## 命令行工具（CLI）

打包后的应用内置命令行工具 `Cell.app/Contents/Helpers/cell`：

```bash
# 运行、添加与分析软件
cell run <setup.exe|.msi> [--container <name>]    # 运行安装程序或可执行文件
cell add <program.exe|folder> [--container <name>] # 添加可执行文件或直接导入软件文件夹
cell launch --app <id> [--backend d3dmetal|dxmt|dxvk|wined3d]
cell analyze <game.exe>                            # 分析引擎、图形 API、DPI 感知与推荐后端
cell plan --app <id>                               # 预览完整启动方案与环境变量

# 容器、引擎与迁移
cell list | containers | engines
cell check-engines [--again]                       # 无头检测各引擎与图形后端组合
cell import-engine <path>                          # 导入 Wine 引擎
cell import-d3dmetal <path>                        # 导入 D3DMetal (GPTK .dmg 或目录)
cell import-dxmt <path>                            # 导入 DXMT
cell bottles                                       # 发现本机 CrossOver / Porting Kit / Whisky 容器
cell import-bottle <name|path>                     # 迁移已有容器

# 插件管理 (.cell)
cell plugin list | validate <path> | import <path> | export <id> <file.cell>
cell plugin new <name> [--id ...] [--exe ...] [--steam-app-id ...]
cell plugin pack <source-folder> <file.cell>

# 虚拟机管理 (.cellvm)
cell vm list
cell vm create --name <n> --guest linux|macos|windows|android [--installer <iso|ipsw>]
cell vm start <name|id> [--seconds 30]
cell vm delete <name|id>

# 网络诊断
cell nat-test                                      # 检测 VPN/代理 UDP 穿透与 NAT 类型
```

---

## 从源码构建与项目结构

### 构建运行
```bash
git clone https://github.com/EgoGold/Cell.git
cd Cell

# 构建完整 Release 应用包（自动编译原生 Helper、打包内置 .cell 插件并生成 build/Cell.app）
./Scripts/build-app.sh
open build/Cell.app

# 开发与测试
swift test
```

### 目录结构
```text
Sources/
├── CellCore/        核心逻辑层（容器、引擎管理、PE/引擎分析、Autopilot、插件系统、虚拟机、网络与日志诊断）
├── CellUI/          原生 SwiftUI 界面层与设计规范（Theme.swift）
├── Cell/            macOS 应用入口
├── CellCLI/         `cell` 命令行工具与快捷方式高速启动器
└── CellArchive/     libarchive 封装（用于安全解包 .cell 插件）
Plugins/             内置兼容数据库（20 个 .cell 插件源码目录）
Examples/            开发者插件示例（Sky Support.cell 及完整 C/Shell 源码）
Tools/               底层原生辅助工具（engine-probe、game-hotkey、dock-name、webview-bridge、steamwebhelper-wrapper 与轻量 PE 链接器）
Resources/           应用图标、Info.plist、虚拟化权限声明（Cell.entitlements）
Scripts/             一键构建脚本（build-app.sh）
Docs/                插件编写指南（PLUGINS.md）
Tests/               CellCore 单元测试套件
```

### 本地数据位置
所有容器、引擎、插件、图标和虚拟机均存放于：
- 数据目录：`~/Library/Application Support/Cell`
- 日志目录：`~/Library/Logs/Cell`

---

## 现状与已知限制

Cell 目前处于 **Beta 测试阶段**，我们正在持续推进软件/游戏适配与底层优化：

- **持续适配中**：不同引擎与游戏（如部分 D3D12 游戏、依赖特殊内核反作弊的网游、特定多媒体解码或切屏输入场景）仍在不断排查和完善；
- **已知边界**：
  - 依赖 Windows 内核级驱动的反作弊系统（如部分 EAC / BattlEye 内核模式）在 Wine 下暂无法运行，Cell 会在启动前主动提示。
  - macOS 上的 Wine 暂不支持非串口类的 USB 设备与蓝牙直通（串口设备已可通过插件 `devices.serialPorts` 映射）。
  - Windows on Arm 与 Android 虚拟机目前为实验性功能，受限于 Apple Virtualization 硬件模拟特性（无虚拟 TPM 及部分驱动缺失）。

---

## 开源协议与致谢

- 本项目基于 **[Apache License 2.0](LICENSE)** 协议开源。
- **不分发专有文件**：Cell 不内置、不分发 Apple **D3DMetal**（Game Porting Toolkit）及任何操作系统的安装镜像（Windows / macOS / Linux / Android），所有专有组件或系统镜像均由用户自行准备并在本地导入。
- 感谢 **Wine**、**DXMT**、**DXVK**、**MoltenVK**、**Gcenx** 及 macOS 兼容层开源社区的长期贡献。
