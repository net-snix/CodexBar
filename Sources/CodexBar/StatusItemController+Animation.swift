import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let loadingPercentEpsilon = 0.0001
    private static let motionEpsilon: CGFloat = 0.0001
    private static let loadingBarWidthPx: CGFloat = 30
    private static let loadingBlinkBucketCount: CGFloat = 12
    private static let loadingMorphBucketCount = 200

    func needsMenuBarIconAnimation() -> Bool {
        if self.shouldMergeIcons {
            let primaryProvider = self.primaryProviderForUnifiedIcon()
            return self.shouldAnimate(provider: primaryProvider)
        }
        return UsageProvider.allCases.contains { self.shouldAnimate(provider: $0) }
    }

    func updateBlinkingState() {
        // During the loading animation, blink ticks can overwrite the animated menu bar icon and cause flicker.
        if self.needsMenuBarIconAnimation() {
            self.stopBlinking()
            return
        }

        let blinkingEnabled = self.isBlinkingAllowed()
        // Cache enabled providers to avoid repeated enablement lookups.
        let enabledProviders = self.store.enabledProviders()
        let anyEnabled = !enabledProviders.isEmpty || self.store.debugForceAnimation
        let anyVisible = UsageProvider.allCases.contains { self.isVisible($0) }
        let mergeIcons = self.settings.mergeIcons && enabledProviders.count > 1
        let shouldBlink = mergeIcons ? anyEnabled : anyVisible
        if blinkingEnabled, shouldBlink {
            if self.blinkTask == nil {
                self.seedBlinkStatesIfNeeded()
                self.blinkTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(75))
                        await MainActor.run { self?.tickBlink() }
                    }
                }
            }
        } else {
            self.stopBlinking()
        }
    }

    private func seedBlinkStatesIfNeeded() {
        let now = Date()
        for provider in UsageProvider.allCases where self.blinkStates[provider] == nil {
            self.blinkStates[provider] = BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
        }
    }

    private func stopBlinking() {
        let hadTask = self.blinkTask != nil
        let hadMotion = !self.blinkAmounts.isEmpty || !self.wiggleAmounts.isEmpty || !self.tiltAmounts.isEmpty
        self.blinkTask?.cancel()
        self.blinkTask = nil
        self.blinkAmounts.removeAll()
        self.wiggleAmounts.removeAll()
        self.tiltAmounts.removeAll()
        guard hadTask || hadMotion else { return }
        let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
        if self.shouldMergeIcons {
            self.applyIcon(phase: phase)
        } else {
            for provider in UsageProvider.allCases {
                self.applyIcon(for: provider, phase: phase)
            }
        }
    }

    private func tickBlink(now: Date = .init()) {
        guard self.isBlinkingAllowed(at: now) else {
            self.stopBlinking()
            return
        }

        let blinkDuration: TimeInterval = 0.36
        let doubleBlinkChance = 0.18
        let doubleDelayRange: ClosedRange<TimeInterval> = 0.22...0.34
        // Cache merge state once per tick to avoid repeated enabled-provider lookups.
        let mergeIcons = self.shouldMergeIcons
        var mergedIconNeedsRefresh = false

        for provider in UsageProvider.allCases {
            let previous = self.motionSnapshot(for: provider)
            let shouldRender = mergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldRender, !self.shouldAnimate(provider: provider, mergeIcons: mergeIcons) else {
                self.clearMotion(for: provider)
                if self.motionChanged(previous, self.motionSnapshot(for: provider)) {
                    if mergeIcons {
                        mergedIconNeedsRefresh = true
                    } else {
                        self.applyIcon(for: provider, phase: nil)
                    }
                }
                continue
            }

            var state = self
                .blinkStates[provider] ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))

            if let pendingSecond = state.pendingSecondStart, now >= pendingSecond {
                state.blinkStart = now
                state.pendingSecondStart = nil
            }

            if let start = state.blinkStart {
                let elapsed = now.timeIntervalSince(start)
                if elapsed >= blinkDuration {
                    state.blinkStart = nil
                    if let pending = state.pendingSecondStart, now < pending {
                        // Wait for the planned double-blink.
                    } else {
                        state.pendingSecondStart = nil
                        state.nextBlink = now.addingTimeInterval(BlinkState.randomDelay())
                    }
                    self.clearMotion(for: provider)
                } else {
                    let progress = max(0, min(elapsed / blinkDuration, 1))
                    let symmetric = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                    let eased = pow(symmetric, 2.2) // slightly punchier than smoothstep
                    self.assignMotion(amount: CGFloat(eased), for: provider, effect: state.effect)
                }
            } else if now >= state.nextBlink {
                state.blinkStart = now
                state.effect = self.randomEffect(for: provider)
                if state.effect == .blink, Double.random(in: 0...1) < doubleBlinkChance {
                    state.pendingSecondStart = now.addingTimeInterval(Double.random(in: doubleDelayRange))
                }
                self.clearMotion(for: provider)
            } else {
                self.clearMotion(for: provider)
            }

            self.blinkStates[provider] = state
            let changed = self.motionChanged(previous, self.motionSnapshot(for: provider))
            if changed, !mergeIcons {
                self.applyIcon(for: provider, phase: nil)
            } else if changed {
                mergedIconNeedsRefresh = true
            }
        }
        if mergeIcons, mergedIconNeedsRefresh {
            let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
            self.applyIcon(phase: phase)
        }
    }

    private func motionSnapshot(for provider: UsageProvider) -> (blink: CGFloat, wiggle: CGFloat, tilt: CGFloat) {
        (self.blinkAmounts[provider] ?? 0, self.wiggleAmounts[provider] ?? 0, self.tiltAmounts[provider] ?? 0)
    }

    private func motionChanged(
        _ previous: (blink: CGFloat, wiggle: CGFloat, tilt: CGFloat),
        _ current: (blink: CGFloat, wiggle: CGFloat, tilt: CGFloat)) -> Bool
    {
        abs(previous.blink - current.blink) > Self.motionEpsilon ||
            abs(previous.wiggle - current.wiggle) > Self.motionEpsilon ||
            abs(previous.tilt - current.tilt) > Self.motionEpsilon
    }

    private func blinkAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.blinkAmounts[provider] ?? 0
    }

    private func wiggleAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.wiggleAmounts[provider] ?? 0
    }

    private func tiltAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.tiltAmounts[provider] ?? 0
    }

    private func assignMotion(amount: CGFloat, for provider: UsageProvider, effect: MotionEffect) {
        switch effect {
        case .blink:
            self.blinkAmounts[provider] = amount
            self.wiggleAmounts[provider] = 0
            self.tiltAmounts[provider] = 0
        case .wiggle:
            self.wiggleAmounts[provider] = amount
            self.blinkAmounts[provider] = 0
            self.tiltAmounts[provider] = 0
        case .tilt:
            self.tiltAmounts[provider] = amount
            self.blinkAmounts[provider] = 0
            self.wiggleAmounts[provider] = 0
        }
    }

    private func clearMotion(for provider: UsageProvider) {
        self.blinkAmounts[provider] = 0
        self.wiggleAmounts[provider] = 0
        self.tiltAmounts[provider] = 0
    }

    private func randomEffect(for provider: UsageProvider) -> MotionEffect {
        if provider == .claude {
            Bool.random() ? .blink : .wiggle
        } else {
            Bool.random() ? .blink : .tilt
        }
    }

    private func isBlinkingAllowed(at date: Date = .init()) -> Bool {
        if self.settings.randomBlinkEnabled { return true }
        if let until = self.blinkForceUntil, until > date { return true }
        self.blinkForceUntil = nil
        return false
    }

    func applyIcon(phase: Double?) {
        guard let button = self.statusItem.button else { return }

        let style = self.store.iconStyle
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let primaryProvider = self.primaryProviderForUnifiedIcon()
        let snapshot = self.store.snapshot(for: primaryProvider)

        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        var primary = showUsed ? snapshot?.primary?.usedPercent : snapshot?.primary?.remainingPercent
        var weekly = showUsed ? snapshot?.secondary?.usedPercent : snapshot?.secondary?.remainingPercent
        if showUsed,
           primaryProvider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining <= 0
        {
            // Preserve Warp "no bonus/exhausted bonus" layout even in show-used mode.
            weekly = 0
        }
        if showUsed,
           primaryProvider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining > 0,
           weekly == 0
        {
            // In show-used mode, `0` means "unused", not "missing". Keep the weekly lane present.
            weekly = Self.loadingPercentEpsilon
        }
        var credits: Double? = primaryProvider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: primaryProvider)
        var morphProgress: Double?

        let needsAnimation = self.needsMenuBarIconAnimation()
        if let phase, needsAnimation {
            var pattern = self.animationPattern
            if style == .combined, pattern == .unbraid {
                pattern = .cylon
            }
            if pattern == .unbraid {
                morphProgress = pattern.value(phase: phase) / 100
                primary = nil
                weekly = nil
                credits = nil
                stale = false
            } else {
                // Keep loading animation layout stable: IconRenderer uses `weeklyRemaining > 0` to switch layouts,
                // so hitting an exact 0 would flip between "normal" and "weekly exhausted" rendering.
                primary = max(pattern.value(phase: phase), Self.loadingPercentEpsilon)
                weekly = max(pattern.value(phase: phase + pattern.secondaryOffset), Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

        let rawBlink: CGFloat = style == .combined ? 0 : self.blinkAmount(for: primaryProvider)
        let rawWiggle: CGFloat = style == .combined ? 0 : self.wiggleAmount(for: primaryProvider)
        let rawTilt: CGFloat = style == .combined ? 0 : self.tiltAmount(for: primaryProvider) * .pi / 28
        let motion = self.filteredMotion(blink: rawBlink, wiggle: rawWiggle, tilt: rawTilt, for: style)
        let blink = motion.blink
        let wiggle = motion.wiggle
        let tilt = motion.tilt

        let statusIndicator: ProviderStatusIndicator = {
            for provider in self.store.enabledProviders() {
                let indicator = self.store.statusIndicator(for: provider)
                if indicator.hasIssue { return indicator }
            }
            return .none
        }()

        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: primaryProvider)
        {
            let displayText = self.menuBarDisplayText(for: primaryProvider, snapshot: snapshot)
            self.setButtonImage(brand, for: button)
            self.setButtonTitle(displayText, for: button)
            return
        }

        self.setButtonTitle(nil, for: button)
        let isLoadingFrame = phase != nil && needsAnimation
        if let morphProgress {
            let image = isLoadingFrame
                ? self.cachedLoadingMorphIcon(progress: morphProgress, style: style)
                : IconRenderer.makeMorphIcon(progress: morphProgress, style: style)
            self.setButtonImage(image, for: button)
        } else {
            let image: NSImage = if isLoadingFrame, let primary, let weekly {
                self.cachedLoadingBarsIcon(
                    primaryRemaining: primary,
                    weeklyRemaining: weekly,
                    style: style,
                    statusIndicator: statusIndicator,
                    blink: blink)
            } else {
                IconRenderer.makeIcon(
                    primaryRemaining: primary,
                    weeklyRemaining: weekly,
                    creditsRemaining: credits,
                    stale: stale,
                    style: style,
                    blink: blink,
                    wiggle: wiggle,
                    tilt: tilt,
                    statusIndicator: statusIndicator)
            }
            self.setButtonImage(image, for: button)
        }
    }

    func applyIcon(for provider: UsageProvider, phase: Double?) {
        guard let button = self.statusItems[provider]?.button else { return }
        let snapshot = self.store.snapshot(for: provider)
        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent

        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: provider)
        {
            let displayText = self.menuBarDisplayText(for: provider, snapshot: snapshot)
            self.setButtonImage(brand, for: button)
            self.setButtonTitle(displayText, for: button)
            return
        }
        var primary = showUsed ? snapshot?.primary?.usedPercent : snapshot?.primary?.remainingPercent
        var weekly = showUsed ? snapshot?.secondary?.usedPercent : snapshot?.secondary?.remainingPercent
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining <= 0
        {
            // Preserve Warp "no bonus/exhausted bonus" layout even in show-used mode.
            weekly = 0
        }
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining > 0,
           weekly == 0
        {
            // In show-used mode, `0` means "unused", not "missing". Keep the weekly lane present.
            weekly = Self.loadingPercentEpsilon
        }
        var credits: Double? = provider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: provider)
        var morphProgress: Double?

        let isLoading = phase != nil && self.shouldAnimate(provider: provider)
        if let phase, isLoading {
            var pattern = self.animationPattern
            if provider == .claude, pattern == .unbraid {
                pattern = .cylon
            }
            if pattern == .unbraid {
                morphProgress = pattern.value(phase: phase) / 100
                primary = nil
                weekly = nil
                credits = nil
                stale = false
            } else {
                // Keep loading animation layout stable: IconRenderer switches layouts at `weeklyRemaining == 0`.
                primary = max(pattern.value(phase: phase), Self.loadingPercentEpsilon)
                weekly = max(pattern.value(phase: phase + pattern.secondaryOffset), Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

        let style: IconStyle = self.store.style(for: provider)
        let rawBlink: CGFloat = {
            guard isLoading, style == .warp, let phase else {
                return self.blinkAmount(for: provider)
            }
            let normalized = (sin(phase * 3) + 1) / 2
            return CGFloat(max(0, min(normalized, 1)))
        }()
        let rawWiggle = self.wiggleAmount(for: provider)
        let rawTilt = self.tiltAmount(for: provider) * .pi / 28 // limit to ~6.4°
        let motion = self.filteredMotion(blink: rawBlink, wiggle: rawWiggle, tilt: rawTilt, for: style)
        let blink = motion.blink
        let wiggle = motion.wiggle
        let tilt = motion.tilt
        if let morphProgress {
            let image = isLoading
                ? self.cachedLoadingMorphIcon(progress: morphProgress, style: style)
                : IconRenderer.makeMorphIcon(progress: morphProgress, style: style)
            self.setButtonImage(image, for: button)
        } else {
            self.setButtonTitle(nil, for: button)
            let status = self.store.statusIndicator(for: provider)
            let image: NSImage = if isLoading, let primary, let weekly {
                self.cachedLoadingBarsIcon(
                    primaryRemaining: primary,
                    weeklyRemaining: weekly,
                    style: style,
                    statusIndicator: status,
                    blink: blink)
            } else {
                IconRenderer.makeIcon(
                    primaryRemaining: primary,
                    weeklyRemaining: weekly,
                    creditsRemaining: credits,
                    stale: stale,
                    style: style,
                    blink: blink,
                    wiggle: wiggle,
                    tilt: tilt,
                    statusIndicator: status)
            }
            self.setButtonImage(image, for: button)
        }
    }

    private static func styleSupportsBlink(_ style: IconStyle) -> Bool {
        switch style {
        case .codex, .claude, .gemini, .antigravity, .factory, .warp:
            true
        default:
            false
        }
    }

    private static func styleSupportsWiggle(_ style: IconStyle) -> Bool {
        style == .claude
    }

    private static func styleSupportsTilt(_ style: IconStyle) -> Bool {
        style == .codex
    }

    private func filteredMotion(
        blink: CGFloat,
        wiggle: CGFloat,
        tilt: CGFloat,
        for style: IconStyle) -> (blink: CGFloat, wiggle: CGFloat, tilt: CGFloat)
    {
        let filteredBlink = Self.styleSupportsBlink(style) ? blink : 0
        let filteredWiggle = Self.styleSupportsWiggle(style) ? wiggle : 0
        let filteredTilt = Self.styleSupportsTilt(style) ? tilt : 0
        return (filteredBlink, filteredWiggle, filteredTilt)
    }

    private func cachedLoadingBarsIcon(
        primaryRemaining: Double,
        weeklyRemaining: Double,
        style: IconStyle,
        statusIndicator: ProviderStatusIndicator,
        blink: CGFloat) -> NSImage
    {
        let key = LoadingFrameCacheKey(
            style: style,
            kind: .bars(
                primaryEncodedFill: self.encodedLoadingFill(for: primaryRemaining),
                weeklyEncodedFill: self.encodedLoadingFill(for: weeklyRemaining),
                status: self.statusIndicatorKey(statusIndicator),
                blinkBucket: self.loadingBlinkBucket(for: blink, style: style)))
        return self.cachedLoadingFrame(for: key) {
            IconRenderer.makeIcon(
                primaryRemaining: primaryRemaining,
                weeklyRemaining: weeklyRemaining,
                creditsRemaining: nil,
                stale: false,
                style: style,
                blink: blink,
                wiggle: 0,
                tilt: 0,
                statusIndicator: statusIndicator)
        }
    }

    private func cachedLoadingMorphIcon(progress: Double, style: IconStyle) -> NSImage {
        let bucket = Int((max(0, min(progress, 1)) * Double(Self.loadingMorphBucketCount)).rounded())
        let key = LoadingFrameCacheKey(style: style, kind: .morph(progressBucket: bucket))
        return self.cachedLoadingFrame(for: key) {
            IconRenderer.makeMorphIcon(progress: progress, style: style)
        }
    }

    private func cachedLoadingFrame(for key: LoadingFrameCacheKey, build: () -> NSImage) -> NSImage {
        if let cached = self.loadingFrameCache[key] {
            self.loadingFrameOrder.removeAll { $0 == key }
            self.loadingFrameOrder.append(key)
            return cached
        }

        let image = build()
        self.loadingFrameCache[key] = image
        self.loadingFrameOrder.removeAll { $0 == key }
        self.loadingFrameOrder.append(key)
        while self.loadingFrameOrder.count > Self.loadingFrameCacheLimit {
            let oldest = self.loadingFrameOrder.removeFirst()
            self.loadingFrameCache.removeValue(forKey: oldest)
        }
        return image
    }

    private func encodedLoadingFill(for percent: Double) -> Int {
        let clamped = max(0, min(percent, 100))
        let fill = Int((Self.loadingBarWidthPx * CGFloat(clamped / 100)).rounded())
        let hasPositiveValue = clamped > 0 ? 1 : 0
        return fill * 2 + hasPositiveValue
    }

    private func loadingBlinkBucket(for blink: CGFloat, style: IconStyle) -> Int {
        guard Self.styleSupportsBlink(style) else { return 0 }
        let clamped = max(0, min(blink, 1))
        return Int((clamped * Self.loadingBlinkBucketCount).rounded())
    }

    private func statusIndicatorKey(_ indicator: ProviderStatusIndicator) -> Int {
        switch indicator {
        case .none: 0
        case .minor: 1
        case .major: 2
        case .critical: 3
        case .maintenance: 4
        case .unknown: 5
        }
    }

    private func setButtonImage(_ image: NSImage, for button: NSStatusBarButton) {
        if button.image === image { return }
        button.image = image
    }

    private func setButtonTitle(_ title: String?, for button: NSStatusBarButton) {
        let value = title ?? ""
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
    }

    func menuBarDisplayText(for provider: UsageProvider, snapshot: UsageSnapshot?) -> String? {
        MenuBarDisplayText.displayText(
            mode: self.settings.menuBarDisplayMode,
            provider: provider,
            percentWindow: self.menuBarPercentWindow(for: provider, snapshot: snapshot),
            paceWindow: snapshot?.secondary,
            showUsed: self.settings.usageBarsShowUsed)
    }

    private func menuBarPercentWindow(for provider: UsageProvider, snapshot: UsageSnapshot?) -> RateWindow? {
        self.menuBarMetricWindow(for: provider, snapshot: snapshot)
    }

    private func primaryProviderForUnifiedIcon() -> UsageProvider {
        // When "show highest usage" is enabled, auto-select the provider closest to rate limit.
        if self.settings.menuBarShowsHighestUsage,
           self.shouldMergeIcons,
           let highest = self.store.providerWithHighestUsage()
        {
            return highest.provider
        }
        if self.shouldMergeIcons,
           let selected = self.selectedMenuProvider,
           self.store.isEnabled(selected)
        {
            return selected
        }
        for provider in UsageProvider.allCases {
            if self.store.isEnabled(provider), self.store.snapshot(for: provider) != nil {
                return provider
            }
        }
        if let enabled = self.store.enabledProviders().first {
            return enabled
        }
        return .codex
    }

    @objc func handleDebugBlinkNotification() {
        self.forceBlinkNow()
    }

    private func forceBlinkNow() {
        let now = Date()
        self.blinkForceUntil = now.addingTimeInterval(0.6)
        self.seedBlinkStatesIfNeeded()

        for provider in UsageProvider.allCases {
            let shouldBlink = self.shouldMergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldBlink, !self.shouldAnimate(provider: provider) else { continue }
            var state = self
                .blinkStates[provider] ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
            state.blinkStart = now
            state.pendingSecondStart = nil
            state.effect = self.randomEffect(for: provider)
            state.nextBlink = now.addingTimeInterval(BlinkState.randomDelay())
            self.blinkStates[provider] = state
            self.assignMotion(amount: 0, for: provider, effect: state.effect)
        }

        self.updateBlinkingState()
        self.tickBlink(now: now)
    }

    private func shouldAnimate(provider: UsageProvider, mergeIcons: Bool? = nil) -> Bool {
        if self.store.debugForceAnimation { return true }

        let isMerged = mergeIcons ?? self.shouldMergeIcons
        let isVisible = isMerged ? self.isEnabled(provider) : self.isVisible(provider)
        guard isVisible else { return false }

        // Don't animate for fallback provider - it's only shown as a placeholder when nothing is enabled.
        // Animating the fallback causes unnecessary CPU usage (battery drain). See #269, #139.
        let isEnabled = self.isEnabled(provider)
        let isFallbackOnly = !isEnabled && self.fallbackProvider == provider
        if isFallbackOnly { return false }

        let isStale = self.store.isStale(provider: provider)
        let hasData = self.store.snapshot(for: provider) != nil
        if provider == .warp, !hasData, self.store.refreshingProviders.contains(provider) {
            return true
        }
        return !hasData && !isStale
    }

    func updateAnimationState() {
        let needsAnimation = self.needsMenuBarIconAnimation()
        if needsAnimation {
            if self.animationDriver == nil {
                if let forced = self.settings.debugLoadingPattern {
                    self.animationPattern = forced
                } else if !LoadingPattern.allCases.contains(self.animationPattern) {
                    self.animationPattern = .knightRider
                }
                self.animationPhase = 0
                let driver = DisplayLinkDriver(onTick: { [weak self] in
                    self?.updateAnimationFrame()
                })
                self.animationDriver = driver
                driver.start(fps: 60)
            } else if let forced = self.settings.debugLoadingPattern, forced != self.animationPattern {
                self.animationPattern = forced
                self.animationPhase = 0
            }
        } else {
            self.animationDriver?.stop()
            self.animationDriver = nil
            self.animationPhase = 0
            self.loadingFrameCache.removeAll(keepingCapacity: true)
            self.loadingFrameOrder.removeAll(keepingCapacity: true)
            if self.shouldMergeIcons {
                self.applyIcon(phase: nil)
            } else {
                UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
            }
        }
    }

    private func updateAnimationFrame() {
        self.animationPhase += 0.045 // half-speed animation
        if self.shouldMergeIcons {
            self.applyIcon(phase: self.animationPhase)
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: self.animationPhase) }
        }
    }

    private func advanceAnimationPattern() {
        let patterns = LoadingPattern.allCases
        if let idx = patterns.firstIndex(of: self.animationPattern) {
            let next = patterns.indices.contains(idx + 1) ? patterns[idx + 1] : patterns.first
            self.animationPattern = next ?? .knightRider
        } else {
            self.animationPattern = .knightRider
        }
    }

    @objc func handleDebugReplayNotification(_ notification: Notification) {
        if let raw = notification.userInfo?["pattern"] as? String,
           let selected = LoadingPattern(rawValue: raw)
        {
            self.animationPattern = selected
        } else if let forced = self.settings.debugLoadingPattern {
            self.animationPattern = forced
        } else {
            self.advanceAnimationPattern()
        }
        self.animationPhase = 0
        self.updateAnimationState()
    }
}
