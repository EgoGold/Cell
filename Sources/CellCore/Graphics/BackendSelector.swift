import Foundation

/// The Autopilot's answer: which backend to use, why, and what to try next.
public struct BackendDecision: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case user, plugin, learned, automatic, retry }

    public var backend: GraphicsBackend
    public var reason: String
    public var fallbacks: [GraphicsBackend]
    /// Arguments the game needs for this backend (e.g. Unity's -force-d3d11 under DXMT).
    public var extraArguments: [String]
    public var source: Source
}

/// Graphics Autopilot: picks the best translation layer per game.
public enum BackendSelector {
    /// The app's graphics engines in order of preference, before looking at what is installed, and why.
    public static func policy(analysis: AppAnalysis?, baseBackend: GraphicsBackend = .wined3d) -> (order: [GraphicsBackend], why: String) {
        let apis = analysis?.graphicsAPIs ?? []
        let has12 = apis.contains(.d3d12) || analysis?.hasD3D12AgilitySDK == true
        let legacy = apis.contains(.d3d9) || apis.contains(.d3d8) || apis.contains(.ddraw)
        let engine = analysis?.engine
        // Unity's Windows player draws with Direct3D 11 unless told otherwise; it loads it at run time, so the program
        // only shows OpenGL (Beholder 2 was given Wine's renderer, which has no Direct3D 11 on a Mac).
        let has11 = apis.contains(.d3d11) || apis.contains(.d3d10) || (engine == .unity && !legacy && !has12)
        let unrealMajor = analysis?.engineVersion.flatMap { LooseVersion($0).components.first }

        var policy: [GraphicsBackend]
        var why: String
        if has12 && !has11 {
            if engine == .unity || engine == .unreal {
                policy = [.d3dmetal, .dxmt, .dxvk, .wined3d]
                why = "this \(engine!.displayName) game uses Direct3D 12 and can also run Direct3D 11"
            } else {
                policy = [.d3dmetal, .wined3d]
                why = "this game uses Direct3D 12"
            }
        } else if has12 && has11 {
            if engine == .unreal, (unrealMajor ?? 5) >= 5 {
                policy = [.d3dmetal, .dxmt, .dxvk, .wined3d]
                why = "this Unreal Engine 5 game prefers Direct3D 12"
            } else {
                policy = [.dxmt, .d3dmetal, .dxvk, .wined3d]
                why = "this game supports Direct3D 11 and 12"
            }
        } else if has11 {
            policy = [.dxmt, .d3dmetal, .dxvk, .wined3d]
            why = "this game uses Direct3D 11"
        } else if legacy {
            policy = [.wined3d, .dxvk]
            why = "this game uses Direct3D 9 or older"
        } else if apis.contains(.vulkan) || apis.contains(.opengl) {
            policy = [baseBackend] + GraphicsBackend.allCases.filter { $0 != baseBackend }
            why = "it renders with \(apis.contains(.vulkan) ? "Vulkan" : "OpenGL"), so no Direct3D translation is needed"
        } else {
            policy = [baseBackend] + GraphicsBackend.allCases.filter { $0 != baseBackend }
            why = "no Direct3D usage was detected"
        }
        return (policy, why)
    }

    public static func decide(
        analysis: AppAnalysis?,
        support: [GraphicsBackend: RuntimeManager.BackendSupport],
        fixes: ResolvedFixes = ResolvedFixes(),
        learned: LearnedCompat = LearnedCompat(),
        userOverride: GraphicsBackend? = nil,
        containerPreference: GraphicsBackend? = nil,
        baseBackend: GraphicsBackend = .wined3d,
        forced: GraphicsBackend? = nil
    ) -> BackendDecision {
        let apis = analysis?.graphicsAPIs ?? []
        let has12 = apis.contains(.d3d12) || analysis?.hasD3D12AgilitySDK == true
        let legacy = apis.contains(.d3d9) || apis.contains(.d3d8) || apis.contains(.ddraw)
        let engine = analysis?.engine
        let has11 = apis.contains(.d3d11) || apis.contains(.d3d10) || (engine == .unity && !legacy && !has12)
        let is32Bit = analysis?.architecture == .x86
        let (policy, why) = Self.policy(analysis: analysis, baseBackend: baseBackend)

        // Keep only what this engine can actually run.
        var candidates = policy.filter { backend in
            guard let info = support[backend] else { return false }
            if is32Bit && !info.supports32Bit && backend != .wined3d { return false }
            if backend == .wined3d && (has11 || has12) && !legacy && !info.coversModernDirect3D { return false }
            return true
        }
        let eligible = Set(candidates)
        var notes: [String] = []
        if is32Bit && policy.contains(.d3dmetal) { notes.append("D3DMetal does not support 32-bit games") }

        // Container preference is a soft hint.
        if let preferred = containerPreference, candidates.contains(preferred) {
            candidates.removeAll { $0 == preferred }
            candidates.insert(preferred, at: 0)
        }

        var source: BackendDecision.Source = .automatic
        // Plugins.
        let avoided = candidates.filter { fixes.avoidBackends.contains($0) }
        if avoided.count < candidates.count { candidates.removeAll { fixes.avoidBackends.contains($0) } }
        let pluginName = fixes.plugins.last { $0.manifest.fixes?.graphics != nil }?.manifest.name
        for preferred in fixes.preferBackends.reversed() where eligible.contains(preferred) {
            candidates.removeAll { $0 == preferred }
            candidates.insert(preferred, at: 0)
            source = .plugin
        }
        candidates += avoided

        // Learned results.
        let failed = learned.failedBackends
        if !failed.isEmpty {
            let healthy = candidates.filter { !failed.contains($0) }
            candidates = healthy + candidates.filter { failed.contains($0) }
        }
        if let working = learned.workingBackend, candidates.contains(working), userOverride == nil {
            candidates.removeAll { $0 == working }
            candidates.insert(working, at: 0)
            source = .learned
        }

        // The user's explicit choice.
        if let userOverride {
            if eligible.contains(userOverride) {
                candidates.removeAll { $0 == userOverride }
                candidates.insert(userOverride, at: 0)
                source = .user
            } else {
                notes.append("\(userOverride.displayName) is unavailable for this program, so Autopilot chose instead")
            }
        }
        if let forced, eligible.contains(forced) {
            candidates.removeAll { $0 == forced }
            candidates.insert(forced, at: 0)
            source = .retry
        }
        if candidates.isEmpty { candidates = [baseBackend] }

        let chosen = candidates[0]
        var extra: [String] = []
        // Steer engines that can choose their renderer towards the one the backend handles best.
        if engine == .unity && chosen != .d3dmetal && (has11 || has12) { extra.append("-force-d3d11") }
        if engine == .unreal && has12 && has11 && chosen != .d3dmetal { extra.append("-dx11") }

        // Explain the choice in terms of the backend actually chosen.
        let strength: String
        switch chosen {
        case .dxmt: strength = "DXMT is the fastest way to run Direct3D 10/11 on Metal"
        case .d3dmetal: strength = has12 ? "D3DMetal runs Direct3D 12 best" : "D3DMetal is Apple's Direct3D to Metal translator"
        case .dxvk: strength = "DXVK runs it through Vulkan on Metal"
        case .wined3d: strength = legacy && !has11 && !has12 ? "WineD3D handles older DirectX best" : "WineD3D is Wine's own renderer"
        }
        if let preferred = policy.first, preferred != chosen, source == .automatic {
            if support[preferred] == nil {
                notes.insert("\(preferred.displayName) would be the first choice but isn't installed", at: 0)
            } else if failed.contains(preferred) {
                notes.insert("\(preferred.displayName) crashed with this game before", at: 0)
            }
        }
        let lead: String
        switch source {
        case .user: lead = "You chose \(chosen.displayName)"
        case .plugin: lead = "\(chosen.displayName), recommended by \(pluginName ?? "a plugin")"
        case .learned: lead = "\(chosen.displayName), which worked last time"
        case .retry: lead = "Trying \(chosen.displayName) after the previous engine failed"
        case .automatic: lead = strength
        }
        var reason = "\(lead) — \(why)"
        if !notes.isEmpty { reason += ". " + notes.joined(separator: ". ") }
        reason += "."
        return BackendDecision(backend: chosen, reason: reason, fallbacks: Array(candidates.dropFirst()),
                               extraArguments: extra, source: source)
    }
}
