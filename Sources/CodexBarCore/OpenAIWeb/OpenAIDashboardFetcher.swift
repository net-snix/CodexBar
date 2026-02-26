#if os(macOS)
import CoreGraphics
import Foundation
import WebKit

@MainActor
public struct OpenAIDashboardFetcher {
    public enum FetchError: LocalizedError {
        case loginRequired
        case noDashboardData(body: String)

        public var errorDescription: String? {
            switch self {
            case .loginRequired:
                "OpenAI web access requires login."
            case let .noDashboardData(body):
                "OpenAI dashboard data not found. Body sample: \(body.prefix(200))"
            }
        }
    }

    private let usageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    public init() {}

    public nonisolated static func offscreenHostWindowFrame(for visibleFrame: CGRect) -> CGRect {
        let width: CGFloat = min(1200, visibleFrame.width)
        let height: CGFloat = min(1600, visibleFrame.height)

        // Keep the WebView "visible" for WebKit hydration, but never show it to the user.
        // Place the window almost entirely off-screen; leave only a 1×1 px intersection.
        let sliver: CGFloat = 1
        return CGRect(
            x: visibleFrame.maxX - sliver,
            y: visibleFrame.maxY - sliver,
            width: width,
            height: height)
    }

    public nonisolated static func offscreenHostAlphaValue() -> CGFloat {
        // Must be > 0 or WebKit can throttle hydration/timers on the Codex usage SPA.
        0.001
    }

    public struct ProbeResult: Sendable {
        public let href: String?
        public let loginRequired: Bool
        public let workspacePicker: Bool
        public let cloudflareInterstitial: Bool
        public let signedInEmail: String?
        public let bodyText: String?

        public init(
            href: String?,
            loginRequired: Bool,
            workspacePicker: Bool,
            cloudflareInterstitial: Bool,
            signedInEmail: String?,
            bodyText: String?)
        {
            self.href = href
            self.loginRequired = loginRequired
            self.workspacePicker = workspacePicker
            self.cloudflareInterstitial = cloudflareInterstitial
            self.signedInEmail = signedInEmail
            self.bodyText = bodyText
        }
    }

    public func loadLatestDashboard(
        accountEmail: String?,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        requirePrimaryUsageLimit: Bool = false,
        timeout: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        return try await self.loadLatestDashboard(
            websiteDataStore: store,
            logger: logger,
            debugDumpHTML: debugDumpHTML,
            requirePrimaryUsageLimit: requirePrimaryUsageLimit,
            timeout: timeout)
    }

    public func loadLatestDashboard(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        requirePrimaryUsageLimit: Bool = false,
        timeout: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        let lease = try await self.makeWebView(websiteDataStore: websiteDataStore, logger: logger)
        defer { lease.release() }
        return try await self.pollLatestDashboard(
            webView: lease.webView,
            log: lease.log,
            debugDumpHTML: debugDumpHTML,
            requirePrimaryUsageLimit: requirePrimaryUsageLimit,
            timeout: timeout)
    }

    private struct PollState {
        var lastBody: String?
        var lastHTML: String?
        var lastHref: String?
        var lastFlags: (loginRequired: Bool, workspacePicker: Bool, cloudflare: Bool)?
        var codeReviewFirstSeenAt: Date?
        var anyDashboardSignalAt: Date?
        var creditsHeaderVisibleAt: Date?
        var lastUsageBreakdownDebug: String?
        var lastCreditsPurchaseURL: String?
        var loginSignalFirstSeenAt: Date?
        var cache = PollCache()
    }

    private struct PollCache {
        var bodyText: String?
        var codeReview: Double?
        var sparkRemaining: Double?
        var rateLimits: (primary: RateWindow?, secondary: RateWindow?) = (nil, nil)
        var creditsRemaining: Double?
        var rows: [[String]] = []
        var events: [CreditEvent] = []
        var breakdown: [OpenAIDashboardDailyBreakdown] = []
        var planHTML: String?
        var accountPlan: String?
    }

    private struct BodyMetrics {
        let codeReview: Double?
        let sparkRemaining: Double?
        let rateLimits: (primary: RateWindow?, secondary: RateWindow?)
        let creditsRemaining: Double?
    }

    private struct CreditMetrics {
        let events: [CreditEvent]
        let breakdown: [OpenAIDashboardDailyBreakdown]
    }

    private struct PollEvaluation {
        let scrape: ScrapeResult
        let bodyMetrics: BodyMetrics
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let hasUsageLimits: Bool
        let events: [CreditEvent]
    }

    private func pollLatestDashboard(
        webView: WKWebView,
        log: (String) -> Void,
        debugDumpHTML: Bool,
        requirePrimaryUsageLimit: Bool,
        timeout: TimeInterval) async throws -> OpenAIDashboardSnapshot
    {
        let deadline = Date().addingTimeInterval(timeout)
        var state = PollState()

        while Date() < deadline {
            let scrape = try await self.scrape(webView: webView)
            self.recordScrape(scrape, state: &state, log: log)

            if scrape.workspacePicker {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            if try await self.handleLoginRequired(
                scrape: scrape,
                webView: webView,
                log: log,
                debugDumpHTML: debugDumpHTML,
                loginSignalFirstSeenAt: &state.loginSignalFirstSeenAt)
            {
                continue
            }
            state.loginSignalFirstSeenAt = nil

            try self.throwIfCloudflare(scrape, debugDumpHTML: debugDumpHTML, log: log)

            if self.needsUsagePageReload(href: scrape.href) {
                _ = webView.load(URLRequest(url: self.usageURL))
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            let bodyMetrics = self.parseBodyMetrics(bodyText: scrape.bodyText ?? "", state: &state)
            let creditMetrics = self.parseCreditMetrics(rows: scrape.rows, state: &state)
            let usageBreakdown = scrape.usageBreakdown
            let hasPrimaryLimit = bodyMetrics.rateLimits.primary != nil
            let hasUsageLimits = hasPrimaryLimit || bodyMetrics.rateLimits.secondary != nil
            let accountPlan = self.parseAccountPlan(bodyHTML: scrape.bodyHTML, state: &state)
            let evaluation = PollEvaluation(
                scrape: scrape,
                bodyMetrics: bodyMetrics,
                usageBreakdown: usageBreakdown,
                hasUsageLimits: hasUsageLimits,
                events: creditMetrics.events)

            self.recordDashboardSignals(
                evaluation: evaluation,
                state: &state,
                log: log)

            if self.shouldWaitForCreditsHistoryRows(
                evaluation: evaluation,
                state: &state,
                log: log)
            {
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            if self.hasDashboardData(
                bodyMetrics: bodyMetrics,
                usageBreakdown: usageBreakdown,
                events: creditMetrics.events,
                hasUsageLimits: hasUsageLimits)
            {
                if requirePrimaryUsageLimit, !hasPrimaryLimit {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }

                if self.shouldWaitForUsageBreakdown(
                    codeReview: bodyMetrics.codeReview,
                    usageBreakdown: usageBreakdown,
                    codeReviewFirstSeenAt: state.codeReviewFirstSeenAt)
                {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }

                return self.makeSnapshot(
                    scrape: scrape,
                    bodyMetrics: bodyMetrics,
                    creditMetrics: creditMetrics,
                    usageBreakdown: usageBreakdown,
                    accountPlan: accountPlan)
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if debugDumpHTML, let html = state.lastHTML {
            Self.writeDebugArtifacts(html: html, bodyText: state.lastBody, logger: log)
        }
        throw FetchError.noDashboardData(body: state.lastBody ?? "")
    }

    private func recordScrape(_ scrape: ScrapeResult, state: inout PollState, log: (String) -> Void) {
        state.lastBody = scrape.bodyText ?? state.lastBody
        state.lastHTML = scrape.bodyHTML ?? state.lastHTML

        if scrape.href != state.lastHref
            || state.lastFlags?.loginRequired != scrape.loginRequired
            || state.lastFlags?.workspacePicker != scrape.workspacePicker
            || state.lastFlags?.cloudflare != scrape.cloudflareInterstitial
        {
            state.lastHref = scrape.href
            state.lastFlags = (scrape.loginRequired, scrape.workspacePicker, scrape.cloudflareInterstitial)
            let href = scrape.href ?? "nil"
            log(
                "href=\(href) login=\(scrape.loginRequired) " +
                    "workspace=\(scrape.workspacePicker) cloudflare=\(scrape.cloudflareInterstitial)")
        }
    }

    private func throwIfCloudflare(
        _ scrape: ScrapeResult,
        debugDumpHTML: Bool,
        log: (String) -> Void) throws
    {
        guard scrape.cloudflareInterstitial else { return }
        if debugDumpHTML, let html = scrape.bodyHTML {
            Self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: log)
        }
        throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
    }

    private func needsUsagePageReload(href: String?) -> Bool {
        guard let href else { return false }
        return !href.contains("/codex/settings/usage")
    }

    private func parseBodyMetrics(bodyText: String, state: inout PollState) -> BodyMetrics {
        if let cachedBodyText = state.cache.bodyText, cachedBodyText == bodyText {
            PerformanceProbe.count("openai_dashboard.parse.body_cache_hit")
            return BodyMetrics(
                codeReview: state.cache.codeReview,
                sparkRemaining: state.cache.sparkRemaining,
                rateLimits: state.cache.rateLimits,
                creditsRemaining: state.cache.creditsRemaining)
        }

        PerformanceProbe.count("openai_dashboard.parse.body_cache_miss")
        let parsedCodeReview = OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: bodyText)
        let parsedSparkRemaining = OpenAIDashboardParser.parseSparkRemainingPercent(bodyText: bodyText)
        let parsedRateLimits = OpenAIDashboardParser.parseRateLimits(bodyText: bodyText)
        let parsedCreditsRemaining = OpenAIDashboardParser.parseCreditsRemaining(bodyText: bodyText)

        state.cache.bodyText = bodyText
        state.cache.codeReview = parsedCodeReview
        state.cache.sparkRemaining = parsedSparkRemaining
        state.cache.rateLimits = parsedRateLimits
        state.cache.creditsRemaining = parsedCreditsRemaining

        return BodyMetrics(
            codeReview: parsedCodeReview,
            sparkRemaining: parsedSparkRemaining,
            rateLimits: parsedRateLimits,
            creditsRemaining: parsedCreditsRemaining)
    }

    private func parseCreditMetrics(rows: [[String]], state: inout PollState) -> CreditMetrics {
        if state.cache.rows == rows {
            PerformanceProbe.count("openai_dashboard.parse.rows_cache_hit")
            return CreditMetrics(events: state.cache.events, breakdown: state.cache.breakdown)
        }

        PerformanceProbe.count("openai_dashboard.parse.rows_cache_miss")
        let parsedEvents = OpenAIDashboardParser.parseCreditEvents(rows: rows)
        let parsedBreakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: parsedEvents, maxDays: 30)
        state.cache.rows = rows
        state.cache.events = parsedEvents
        state.cache.breakdown = parsedBreakdown
        return CreditMetrics(events: parsedEvents, breakdown: parsedBreakdown)
    }

    private func parseAccountPlan(bodyHTML: String?, state: inout PollState) -> String? {
        if state.cache.planHTML == bodyHTML {
            PerformanceProbe.count("openai_dashboard.parse.plan_cache_hit")
            return state.cache.accountPlan
        }

        PerformanceProbe.count("openai_dashboard.parse.plan_cache_miss")
        let parsedAccountPlan = bodyHTML.flatMap(OpenAIDashboardParser.parsePlanFromHTML)
        state.cache.planHTML = bodyHTML
        state.cache.accountPlan = parsedAccountPlan
        return parsedAccountPlan
    }

    private func recordDashboardSignals(
        evaluation: PollEvaluation,
        state: inout PollState,
        log: (String) -> Void)
    {
        let now = Date()
        if evaluation.bodyMetrics.codeReview != nil, state.codeReviewFirstSeenAt == nil {
            state.codeReviewFirstSeenAt = now
        }

        if state.anyDashboardSignalAt == nil,
           self.hasDashboardSignal(
               bodyMetrics: evaluation.bodyMetrics,
               usageBreakdown: evaluation.usageBreakdown,
               creditsHeaderPresent: evaluation.scrape.creditsHeaderPresent,
               hasUsageLimits: evaluation.hasUsageLimits)
        {
            state.anyDashboardSignalAt = now
        }

        if evaluation.bodyMetrics.codeReview != nil,
           evaluation.usageBreakdown.isEmpty,
           let debug = evaluation.scrape.usageBreakdownDebug,
           !debug.isEmpty,
           debug != state.lastUsageBreakdownDebug
        {
            state.lastUsageBreakdownDebug = debug
            log("usage breakdown debug: \(debug)")
        }

        if let purchaseURL = evaluation.scrape.creditsPurchaseURL, purchaseURL != state.lastCreditsPurchaseURL {
            state.lastCreditsPurchaseURL = purchaseURL
            log("credits purchase url: \(purchaseURL)")
        }
    }

    private func shouldWaitForCreditsHistoryRows(
        evaluation: PollEvaluation,
        state: inout PollState,
        log: (String) -> Void) -> Bool
    {
        guard evaluation.events.isEmpty else { return false }
        guard self.hasDashboardSignal(
            bodyMetrics: evaluation.bodyMetrics,
            usageBreakdown: evaluation.usageBreakdown,
            creditsHeaderPresent: evaluation.scrape.creditsHeaderPresent,
            hasUsageLimits: evaluation.hasUsageLimits)
        else { return false }

        log(
            "credits header present=\(evaluation.scrape.creditsHeaderPresent) " +
                "inViewport=\(evaluation.scrape.creditsHeaderInViewport) " +
                "didScroll=\(evaluation.scrape.didScrollToCredits) " +
                "rows=\(evaluation.scrape.rows.count)")
        if evaluation.scrape.didScrollToCredits {
            log("scrollIntoView(Credits usage history) requested; waiting…")
            return true
        }

        if evaluation.scrape.creditsHeaderPresent,
           evaluation.scrape.creditsHeaderInViewport,
           state.creditsHeaderVisibleAt == nil
        {
            state.creditsHeaderVisibleAt = Date()
        }
        return Self.shouldWaitForCreditsHistory(.init(
            now: Date(),
            anyDashboardSignalAt: state.anyDashboardSignalAt,
            creditsHeaderVisibleAt: state.creditsHeaderVisibleAt,
            creditsHeaderPresent: evaluation.scrape.creditsHeaderPresent,
            creditsHeaderInViewport: evaluation.scrape.creditsHeaderInViewport,
            didScrollToCredits: evaluation.scrape.didScrollToCredits))
    }

    private func hasDashboardSignal(
        bodyMetrics: BodyMetrics,
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        creditsHeaderPresent: Bool,
        hasUsageLimits: Bool) -> Bool
    {
        bodyMetrics.codeReview != nil ||
            bodyMetrics.sparkRemaining != nil ||
            !usageBreakdown.isEmpty ||
            creditsHeaderPresent ||
            hasUsageLimits ||
            bodyMetrics.creditsRemaining != nil
    }

    private func hasDashboardData(
        bodyMetrics: BodyMetrics,
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        events: [CreditEvent],
        hasUsageLimits: Bool) -> Bool
    {
        bodyMetrics.codeReview != nil ||
            bodyMetrics.sparkRemaining != nil ||
            !events.isEmpty ||
            !usageBreakdown.isEmpty ||
            hasUsageLimits ||
            bodyMetrics.creditsRemaining != nil
    }

    private func shouldWaitForUsageBreakdown(
        codeReview: Double?,
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        codeReviewFirstSeenAt: Date?) -> Bool
    {
        guard codeReview != nil, usageBreakdown.isEmpty else { return false }
        let elapsed = Date().timeIntervalSince(codeReviewFirstSeenAt ?? Date())
        return elapsed < 6
    }

    private func makeSnapshot(
        scrape: ScrapeResult,
        bodyMetrics: BodyMetrics,
        creditMetrics: CreditMetrics,
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        accountPlan: String?) -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: scrape.signedInEmail,
            codeReviewRemainingPercent: bodyMetrics.codeReview,
            sparkRemainingPercent: bodyMetrics.sparkRemaining,
            creditEvents: creditMetrics.events,
            dailyBreakdown: creditMetrics.breakdown,
            usageBreakdown: usageBreakdown,
            creditsPurchaseURL: scrape.creditsPurchaseURL,
            primaryLimit: bodyMetrics.rateLimits.primary,
            secondaryLimit: bodyMetrics.rateLimits.secondary,
            creditsRemaining: bodyMetrics.creditsRemaining,
            accountPlan: accountPlan,
            updatedAt: Date())
    }

    struct CreditsHistoryWaitContext: Sendable {
        let now: Date
        let anyDashboardSignalAt: Date?
        let creditsHeaderVisibleAt: Date?
        let creditsHeaderPresent: Bool
        let creditsHeaderInViewport: Bool
        let didScrollToCredits: Bool
    }

    nonisolated static func shouldWaitForCreditsHistory(_ context: CreditsHistoryWaitContext) -> Bool {
        if context.didScrollToCredits { return true }

        // When the header is visible but rows are still empty, wait briefly for the table to render.
        if context.creditsHeaderPresent, context.creditsHeaderInViewport {
            if let creditsHeaderVisibleAt = context.creditsHeaderVisibleAt {
                return context.now.timeIntervalSince(creditsHeaderVisibleAt) < 2.5
            }
            return true
        }

        // Header not in view yet: allow a short grace period after we first detect any dashboard signal so
        // a scroll (or hydration) can bring the credits section into the DOM.
        if let anyDashboardSignalAt = context.anyDashboardSignalAt {
            return context.now.timeIntervalSince(anyDashboardSignalAt) < 6.5
        }
        return false
    }

    @MainActor
    private func handleLoginRequired(
        scrape: ScrapeResult,
        webView: WKWebView,
        log: (String) -> Void,
        debugDumpHTML: Bool,
        loginSignalFirstSeenAt: inout Date?) async throws -> Bool
    {
        guard scrape.loginRequired else { return false }
        let now = Date()
        let hrefLower = scrape.href?.lowercased() ?? ""
        let onExplicitLoginRoute = hrefLower.contains("/auth/") || hrefLower.contains("/login")
        let hasSignedInEmail = scrape.signedInEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let authStatus = scrape.authStatus?.lowercased()
        if loginSignalFirstSeenAt == nil { loginSignalFirstSeenAt = now }
        let elapsed = now.timeIntervalSince(loginSignalFirstSeenAt ?? now)
        let shouldRetryTransientLogin = authStatus == "logged_in" || hasSignedInEmail
            || (!onExplicitLoginRoute && elapsed < 8)
        if shouldRetryTransientLogin {
            if !onExplicitLoginRoute {
                _ = webView.load(URLRequest(url: self.usageURL))
            }
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }
        if debugDumpHTML, let html = scrape.bodyHTML {
            Self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: log)
        }
        throw FetchError.loginRequired
    }

    public func clearSessionData(accountEmail: String?) async {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        OpenAIDashboardWebViewCache.shared.evict(websiteDataStore: store)
        await OpenAIDashboardWebsiteDataStore.clearStore(forAccountEmail: accountEmail)
    }

    public func probeUsagePage(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        timeout: TimeInterval = 30) async throws -> ProbeResult
    {
        let lease = try await self.makeWebView(websiteDataStore: websiteDataStore, logger: logger)
        defer { lease.release() }
        let webView = lease.webView
        let log = lease.log

        let deadline = Date().addingTimeInterval(timeout)
        var lastBody: String?
        var lastHref: String?
        var loginSignalFirstSeenAt: Date?

        while Date() < deadline {
            let scrape = try await self.scrape(webView: webView)
            lastBody = scrape.bodyText ?? lastBody
            lastHref = scrape.href ?? lastHref

            if scrape.workspacePicker {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            if scrape.loginRequired {
                let now = Date()
                let hrefLower = scrape.href?.lowercased() ?? ""
                let onExplicitLoginRoute = hrefLower.contains("/auth/") || hrefLower.contains("/login")
                let hasSignedInEmail = scrape.signedInEmail?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
                let authStatus = scrape.authStatus?.lowercased()
                if loginSignalFirstSeenAt == nil { loginSignalFirstSeenAt = now }
                let elapsed = now.timeIntervalSince(loginSignalFirstSeenAt ?? now)
                let shouldRetryTransientLogin = authStatus == "logged_in" || hasSignedInEmail
                    || (!onExplicitLoginRoute && elapsed < 6)
                if shouldRetryTransientLogin {
                    if !onExplicitLoginRoute {
                        _ = webView.load(URLRequest(url: self.usageURL))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw FetchError.loginRequired
            }
            loginSignalFirstSeenAt = nil
            if scrape.cloudflareInterstitial {
                throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
            }

            if let href = scrape.href, !href.contains("/codex/settings/usage") {
                _ = webView.load(URLRequest(url: self.usageURL))
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            return ProbeResult(
                href: scrape.href,
                loginRequired: scrape.loginRequired,
                workspacePicker: scrape.workspacePicker,
                cloudflareInterstitial: scrape.cloudflareInterstitial,
                signedInEmail: scrape.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                bodyText: scrape.bodyText)
        }

        log("Probe timed out (href=\(lastHref ?? "nil"))")
        return ProbeResult(
            href: lastHref,
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            signedInEmail: nil,
            bodyText: lastBody)
    }

    // MARK: - JS scrape

    private struct ScrapeResult {
        let loginRequired: Bool
        let workspacePicker: Bool
        let cloudflareInterstitial: Bool
        let href: String?
        let bodyText: String?
        let bodyHTML: String?
        let signedInEmail: String?
        let authStatus: String?
        let creditsPurchaseURL: String?
        let rows: [[String]]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdownDebug: String?
        let scrollY: Double
        let scrollHeight: Double
        let viewportHeight: Double
        let creditsHeaderPresent: Bool
        let creditsHeaderInViewport: Bool
        let didScrollToCredits: Bool
    }

    private func scrape(webView: WKWebView) async throws -> ScrapeResult {
        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        guard let dict = any as? [String: Any] else {
            return ScrapeResult(
                loginRequired: true,
                workspacePicker: false,
                cloudflareInterstitial: false,
                href: nil,
                bodyText: nil,
                bodyHTML: nil,
                signedInEmail: nil,
                authStatus: nil,
                creditsPurchaseURL: nil,
                rows: [],
                usageBreakdown: [],
                usageBreakdownDebug: nil,
                scrollY: 0,
                scrollHeight: 0,
                viewportHeight: 0,
                creditsHeaderPresent: false,
                creditsHeaderInViewport: false,
                didScrollToCredits: false)
        }

        var loginRequired = (dict["loginRequired"] as? Bool) ?? false
        let workspacePicker = (dict["workspacePicker"] as? Bool) ?? false
        let cloudflareInterstitial = (dict["cloudflareInterstitial"] as? Bool) ?? false
        let rows = (dict["rows"] as? [[String]]) ?? []
        let bodyHTML = dict["bodyHTML"] as? String

        var usageBreakdown: [OpenAIDashboardDailyBreakdown] = []
        let usageBreakdownDebug = dict["usageBreakdownDebug"] as? String
        if let raw = dict["usageBreakdownJSON"] as? String, !raw.isEmpty {
            do {
                let decoder = JSONDecoder()
                usageBreakdown = try decoder.decode([OpenAIDashboardDailyBreakdown].self, from: Data(raw.utf8))
            } catch {
                // Best-effort parse; ignore errors to avoid blocking other dashboard data.
                usageBreakdown = []
            }
        }

        var signedInEmail = dict["signedInEmail"] as? String
        if let bodyHTML,
           signedInEmail == nil || signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        {
            signedInEmail = OpenAIDashboardParser.parseSignedInEmailFromClientBootstrap(html: bodyHTML)
        }

        let rawAuthStatus = bodyHTML
            .flatMap { OpenAIDashboardParser.parseAuthStatusFromClientBootstrap(html: $0) }
        let authStatus = rawAuthStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let authStatus = authStatus?.lowercased() {
            if authStatus == "logged_in" {
                loginRequired = false
            } else if authStatus == "logged_out" {
                // Logged-out pages can render a generic shell without auth inputs.
                loginRequired = true
            }
        }

        return ScrapeResult(
            loginRequired: loginRequired,
            workspacePicker: workspacePicker,
            cloudflareInterstitial: cloudflareInterstitial,
            href: dict["href"] as? String,
            bodyText: dict["bodyText"] as? String,
            bodyHTML: bodyHTML,
            signedInEmail: signedInEmail,
            authStatus: authStatus,
            creditsPurchaseURL: dict["creditsPurchaseURL"] as? String,
            rows: rows,
            usageBreakdown: usageBreakdown,
            usageBreakdownDebug: usageBreakdownDebug,
            scrollY: (dict["scrollY"] as? NSNumber)?.doubleValue ?? 0,
            scrollHeight: (dict["scrollHeight"] as? NSNumber)?.doubleValue ?? 0,
            viewportHeight: (dict["viewportHeight"] as? NSNumber)?.doubleValue ?? 0,
            creditsHeaderPresent: (dict["creditsHeaderPresent"] as? Bool) ?? false,
            creditsHeaderInViewport: (dict["creditsHeaderInViewport"] as? Bool) ?? false,
            didScrollToCredits: (dict["didScrollToCredits"] as? Bool) ?? false)
    }

    private func makeWebView(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)?) async throws -> OpenAIDashboardWebViewLease
    {
        try await OpenAIDashboardWebViewCache.shared.acquire(
            websiteDataStore: websiteDataStore,
            usageURL: self.usageURL,
            logger: logger)
    }

    private static func writeDebugArtifacts(html: String, bodyText: String?, logger: (String) -> Void) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let htmlURL = dir.appendingPathComponent("codex-openai-dashboard-\(stamp).html")
        do {
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            logger("Dumped HTML: \(htmlURL.path)")
        } catch {
            logger("Failed to dump HTML: \(error.localizedDescription)")
        }

        if let bodyText, !bodyText.isEmpty {
            let textURL = dir.appendingPathComponent("codex-openai-dashboard-\(stamp).txt")
            do {
                try bodyText.write(to: textURL, atomically: true, encoding: .utf8)
                logger("Dumped text: \(textURL.path)")
            } catch {
                logger("Failed to dump text: \(error.localizedDescription)")
            }
        }
    }
}
#else
import Foundation

@MainActor
public struct OpenAIDashboardFetcher {
    public enum FetchError: LocalizedError {
        case loginRequired
        case noDashboardData(body: String)

        public var errorDescription: String? {
            switch self {
            case .loginRequired:
                "OpenAI web access requires login."
            case let .noDashboardData(body):
                "OpenAI dashboard data not found. Body sample: \(body.prefix(200))"
            }
        }
    }

    public init() {}

    public func loadLatestDashboard(
        accountEmail _: String?,
        logger _: ((String) -> Void)? = nil,
        debugDumpHTML _: Bool = false,
        requirePrimaryUsageLimit _: Bool = false,
        timeout _: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        throw FetchError.noDashboardData(body: "OpenAI web dashboard fetch is only supported on macOS.")
    }
}
#endif
