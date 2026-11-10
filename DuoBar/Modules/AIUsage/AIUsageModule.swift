import Foundation

/// AI Usage module: Claude and Codex plan limits.
///
/// Off by default. Everything happens while the popover is open: Codex limits
/// are read from local session logs, Claude limits are fetched from Anthropic
/// with Claude Code's sign-in (at most every `claudeMinimumInterval` unless
/// the user refreshes). No timers; nothing runs with the popover closed.
@MainActor
final class AIUsageModule: ObservableObject, StatusModule {
    let id: ModuleID = .aiUsage

    @Published private(set) var claude: ProviderUsageState = .off
    @Published private(set) var codex: ProviderUsageState = .off

    private let codexReader: any CodexUsageReading
    private let credentialsReader: any ClaudeCredentialsReading
    private let fetcher: any ClaudeUsageFetching
    private let defaults: UserDefaults
    private let now: () -> Date
    private let queue = DispatchQueue(label: "DuoBarPlus.AIUsage", qos: .userInitiated)
    let claudeMinimumInterval: TimeInterval

    /// Kept in memory only, so the Keychain is asked at most once per launch
    /// (and again after the sign-in expires).
    private var credentials: ClaudeCredentials?
    private var lastClaudeAttempt: Date?
    /// The token that last ran out or was refused, so it is not sent again.
    private var rejectedToken: String?
    private var generation = 0
    private(set) var claudeFetchCount = 0

    init(
        codexReader: any CodexUsageReading = CodexUsageReader(),
        credentialsReader: any ClaudeCredentialsReading = ClaudeCredentialsReader(),
        fetcher: any ClaudeUsageFetching = ClaudeUsageFetcher(),
        defaults: UserDefaults = .standard,
        claudeMinimumInterval: TimeInterval = 120,
        now: @escaping () -> Date = Date.init
    ) {
        self.codexReader = codexReader
        self.credentialsReader = credentialsReader
        self.fetcher = fetcher
        self.defaults = defaults
        self.claudeMinimumInterval = claudeMinimumInterval
        self.now = now
    }

    var showsClaude: Bool { ModuleOption.claudeUsage.isEnabled(in: defaults) }
    var showsCodex: Bool { ModuleOption.codexUsage.isEnabled(in: defaults) }

    func state(for provider: AIProvider) -> ProviderUsageState {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    var enabledProviders: [AIProvider] {
        AIProvider.allCases.filter { $0 == .claude ? showsClaude : showsCodex }
    }

    func popoverDidOpen() { refresh(force: false) }
    func detailDidOpen() { refresh(force: false) }
    func popoverDidClose() { generation += 1 }

    func deactivate() {
        generation += 1
        credentials = nil
        lastClaudeAttempt = nil
        claude = .off
        codex = .off
    }

    /// `force` skips the Claude rate guard (the Refresh button).
    func refresh(force: Bool) {
        generation += 1
        refreshCodex()
        refreshClaude(force: force)
    }

    private func refreshCodex() {
        guard showsCodex else { codex = .off; return }
        if codex.usage == nil { codex = .loading }
        let generation = generation
        let reader = codexReader
        queue.async { [weak self] in
            let usage = reader.latestUsage()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.codex = usage.map(ProviderUsageState.ready) ?? .failed(.noSessions)
            }
        }
    }

    private func refreshClaude(force: Bool) {
        guard showsClaude else { claude = .off; return }
        let date = now()
        // An expired sign-in is read again on every open, so the card recovers
        // as soon as Claude Code has renewed it. Reading the Keychain is local;
        // Anthropic is still asked at most every `claudeMinimumInterval`.
        let isRecovering = claude.problem?.isSignInExpired == true
        if !force, !isRecovering, let lastClaudeAttempt, date.timeIntervalSince(lastClaudeAttempt) < claudeMinimumInterval, claude != .loading {
            return
        }
        if claude.usage == nil, !isRecovering { claude = .loading }
        let generation = generation

        if let credentials, !credentials.isExpired(at: date) {
            fetchClaude(with: credentials, generation: generation)
            return
        }
        credentials = nil
        let reader = credentialsReader
        queue.async { [weak self] in
            let result = Result { try reader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let credentials):
                    if credentials.isExpired(at: self.now()) {
                        self.rejectedToken = credentials.accessToken
                        self.finishClaude(.failed(.signInExpired(credentials.expiresAt)), generation: generation)
                    } else if credentials.accessToken == self.rejectedToken {
                        // Anthropic refused this token before; wait for a new one.
                        self.finishClaude(.failed(.signInExpired(nil)), generation: generation)
                    } else {
                        self.credentials = credentials
                        self.fetchClaude(with: credentials, generation: generation)
                    }
                case .failure(let error):
                    self.finishClaude(.failed((error as? ClaudeCredentialsError) == .denied ? .keychainDenied : .notSignedIn), generation: generation)
                }
            }
        }
    }

    private func fetchClaude(with credentials: ClaudeCredentials, generation: Int) {
        claudeFetchCount += 1
        lastClaudeAttempt = now()
        let fetcher = fetcher
        let measuredAt = now()
        Task { [weak self] in
            let state: ProviderUsageState
            do {
                let (status, data) = try await fetcher.fetch(accessToken: credentials.accessToken)
                switch status {
                case 200:
                    state = ClaudeUsageParser.parse(data, measuredAt: measuredAt, plan: credentials.subscriptionType)
                        .map(ProviderUsageState.ready) ?? .failed(.unreadable)
                case 401, 403:
                    self?.credentials = nil
                    self?.rejectedToken = credentials.accessToken
                    state = .failed(.signInExpired(nil))
                default:
                    state = .failed(.server(status))
                }
            } catch {
                state = .failed(.network(error.localizedDescription))
            }
            self?.finishClaude(state, generation: generation)
        }
    }

    private func finishClaude(_ state: ProviderUsageState, generation: Int) {
        // A newer refresh owns the result; an older one may still fill an
        // empty state (for example after the popover closed and reopened).
        guard generation == self.generation || claude == .loading else { return }
        guard showsClaude else { return }
        // Keep the last numbers on a temporary failure, such as rate limiting.
        if case .failed(let problem) = state, claude.usage != nil, !problem.isSignInExpired, problem != .keychainDenied {
            return
        }
        claude = state
    }
}
