import Foundation

/// Reads the read-only sources, keeping the last good value of each: `worktree ps`, `account list`,
/// `orchestration worker-list`, `status` for this Mac, and `environment list` plus `worktree ps` and
/// `orchestration worker-list` with `--environment` for each paired remote Orca server (`pollEnvironments`).
public actor OrcaCollector {
    public static let minInterval: TimeInterval = 5
    public static let defaultInterval: TimeInterval = 15
    public static let commandTimeout: TimeInterval = 10
    /// A remote server can be slow (network, VPN): its own, longer budget; the local one stays at 10 s.
    public static let environmentTimeout: TimeInterval = 10
    /// Paired servers are re-discovered at most this often (and at launch).
    public static let discoveryInterval: TimeInterval = 60
    static let maxWorkerPages = 50

    let runner: any OrcaCommandRunning
    let timeout: TimeInterval
    var raw = OrcaRawState()
    private var health: [OrcaSource: OrcaSourceHealth] = Dictionary(
        uniqueKeysWithValues: OrcaSource.allCases.map { ($0, OrcaSourceHealth(ok: false)) })
    private var lastCompleteAt: Int?
    let environmentTimeout: TimeInterval
    private var lastDiscoveryAt: Date?
    /// Environments with a read in flight, so a slow server is never asked twice at once.
    private var inFlight = Set<String>()
    private var lastAttemptAt: [String: Date] = [:]
    private var includeEnvironments = true
    private var disabledEnvironmentIds = Set<String>()
    public private(set) var pollInterval: TimeInterval

    public init(runner: any OrcaCommandRunning, pollInterval: TimeInterval = OrcaCollector.defaultInterval,
                commandTimeout: TimeInterval = OrcaCollector.commandTimeout,
                environmentTimeout: TimeInterval = OrcaCollector.environmentTimeout) {
        self.runner = runner
        self.timeout = commandTimeout
        self.environmentTimeout = environmentTimeout
        self.pollInterval = max(pollInterval, Self.minInterval)
    }

    public func setPollInterval(_ interval: TimeInterval) { pollInterval = max(interval, Self.minInterval) }

    /// One collection cycle: all sources concurrently, then the derived snapshot.
    public func collect(includeRemote: Bool = true, now: Date = Date(), calendar: Calendar = .current) async -> OrcaSnapshot {
        async let ps = attempt { try await self.fetchWorktrees() }
        async let acc = attempt { try await self.fetchRateLimits() }
        async let wk = attempt { try await self.fetchWorkers() }
        async let st = attempt { try await self.fetchStatus() }
        let results = await (ps, acc, wk, st)
        let at = Int(now.timeIntervalSince1970)

        func record<T>(_ source: OrcaSource, _ result: Result<T, OrcaCommandError>, _ apply: (T) -> Void) {
            switch result {
            case .success(let value): apply(value); health[source] = OrcaSourceHealth(ok: true, lastSuccessAt: at)
            case .failure(let e):
                health[source] = OrcaSourceHealth(ok: false, lastSuccessAt: health[source]?.lastSuccessAt, error: e.summary)
            }
        }
        record(.worktrees, results.0) { raw.worktrees = $0 }
        record(.accounts, results.1) { raw.rateLimits = $0 }
        record(.workers, results.2) { raw.workers = $0 }
        record(.status, results.3) { raw.status = $0 }
        if health.values.allSatisfy(\.ok) { lastCompleteAt = at }
        return snapshot(includeRemote: includeRemote, now: now, calendar: calendar)
    }

    /// Fast cycle: only `worktree ps` (counters and list); the other sources keep their last good value.
    public func collectFast(includeRemote: Bool = true, now: Date = Date(), calendar: Calendar = .current) async -> OrcaSnapshot {
        let result = await attempt { try await self.fetchWorktrees() }
        let at = Int(now.timeIntervalSince1970)
        switch result {
        case .success(let value):
            raw.worktrees = value
            health[.worktrees] = OrcaSourceHealth(ok: true, lastSuccessAt: at)
        case .failure(let e):
            health[.worktrees] = OrcaSourceHealth(ok: false, lastSuccessAt: health[.worktrees]?.lastSuccessAt, error: e.summary)
        }
        return snapshot(includeRemote: includeRemote, now: now, calendar: calendar)
    }

    /// Which paired environments are read: all of them (`includeAll`) minus the ones the user turned off.
    /// A host that is turned off keeps its entry (so Settings can list it) but is neither polled nor shown.
    public func setEnvironmentPolicy(includeAll: Bool, disabledIds: Set<String>) {
        includeEnvironments = includeAll
        disabledEnvironmentIds = disabledIds
        applyEnvironmentPolicy()
    }

    /// Re-derives from the last good data without touching the CLI.
    public func snapshot(includeRemote: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> OrcaSnapshot {
        OrcaDerivation.derive(raw: raw, sources: health, lastCompleteCycleAt: lastCompleteAt, pollInterval: pollInterval,
                              includeRemote: includeRemote, now: now, calendar: calendar)
    }

    // MARK: - Sources

    private func applyEnvironmentPolicy() {
        for i in raw.environments.indices {
            raw.environments[i].enabled = includeEnvironments && !disabledEnvironmentIds.contains(raw.environments[i].host.id)
        }
    }

    // MARK: - Paired environments

    /// One environment cycle: re-discovers the paired servers when due, then reads every enabled one in
    /// parallel, each with its own timeout. `full` adds `orchestration worker-list`; a fast cycle reads only
    /// `worktree ps`. A failing server keeps its last good rows and is marked offline; it never delays or
    /// empties the others, and an unreachable one is retried at most once per `OrcaPollPolicy.fullRefreshInterval`.
    public func pollEnvironments(full: Bool, includeRemote: Bool = true, now: Date = Date(),
                                 calendar: Calendar = .current) async -> OrcaSnapshot {
        await discoverIfDue(now: now)
        let due = raw.environments.filter { env in
            guard env.enabled, !inFlight.contains(env.host.id) else { return false }
            guard !env.health.ok, let last = lastAttemptAt[env.host.id] else { return true }
            return now.timeIntervalSince(last) >= OrcaPollPolicy.fullRefreshInterval - OrcaPollPolicy.activeInterval / 2
        }
        for env in due { inFlight.insert(env.host.id); lastAttemptAt[env.host.id] = now }
        let runner = runner, timeout = environmentTimeout
        let results = await withTaskGroup(of: (String, Result<[RawWorktree], OrcaCommandError>, Result<[RawWorker], OrcaCommandError>?).self) { group in
            for env in due {
                let id = env.host.id
                group.addTask {
                    let ps = await Self.attempt { try await Self.fetchWorktrees(runner, timeout, environment: id) }
                    // Workers only on a full cycle, and only from a server that answered.
                    guard full, case .success = ps else { return (id, ps, nil) }
                    let workers = await Self.attempt { try await Self.fetchWorkers(runner, timeout, environment: id) }
                    return (id, ps, workers)
                }
            }
            var all: [(String, Result<[RawWorktree], OrcaCommandError>, Result<[RawWorker], OrcaCommandError>?)] = []
            for await r in group { all.append(r) }
            return all
        }
        let at = Int(now.timeIntervalSince1970)
        for (id, ps, workers) in results {
            inFlight.remove(id)
            guard let i = raw.environments.firstIndex(where: { $0.host.id == id }) else { continue }
            switch ps {
            case .success(let value):
                raw.environments[i].worktrees = value
                raw.environments[i].health = OrcaSourceHealth(ok: true, lastSuccessAt: at)
            case .failure(let e):
                let previous = raw.environments[i].health.lastSuccessAt
                raw.environments[i].health = OrcaSourceHealth(ok: false, lastSuccessAt: previous, error: e.summary)
            }
            if case .success(let value)? = workers { raw.environments[i].workers = value }
        }
        return snapshot(includeRemote: includeRemote, now: now, calendar: calendar)
    }

    /// `environment list`, at launch and then about every 60 s. Keeps only id and name; a failed read keeps
    /// the known list. Servers that went away are dropped, new ones start offline until their first read.
    private func discoverIfDue(now: Date) async {
        if let last = lastDiscoveryAt, now.timeIntervalSince(last) < Self.discoveryInterval { return }
        lastDiscoveryAt = now
        guard let envs = try? await decode(RawEnvironmentsResult.self, ["environment", "list", "--json"]).environments else { return }
        let hosts = envs.compactMap { e -> OrcaHost? in
            guard let id = e.id, !id.isEmpty else { return nil }
            return OrcaHost(id: id, name: e.name?.isEmpty == false ? e.name! : id)
        }
        let known = Dictionary(raw.environments.map { ($0.host.id, $0) }, uniquingKeysWith: { a, _ in a })
        raw.environments = hosts.map { host in
            var state = known[host.id] ?? RawEnvironmentState(host: host)
            state.host = host
            return state
        }
        lastAttemptAt = lastAttemptAt.filter { key, _ in hosts.contains { $0.id == key } }
        applyEnvironmentPolicy()
    }

    private static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, OrcaCommandError> {
        do { return .success(try await body()) }
        catch let e as OrcaCommandError { return .failure(e) }
        catch { return .failure(.launchFailed(error.localizedDescription)) }
    }

    private static func decode<R: Decodable>(_ runner: any OrcaCommandRunning, _ timeout: TimeInterval,
                                             _ type: R.Type, _ args: [String]) async throws -> R {
        let data = try await runner.run(arguments: args, timeout: timeout)
        let envelope: OrcaEnvelope<R>
        do { envelope = try JSONDecoder().decode(OrcaEnvelope<R>.self, from: data) }
        catch { throw OrcaCommandError.invalidOutput("not JSON") }
        guard envelope.ok == true, let result = envelope.result else {
            throw OrcaCommandError.invalidOutput(envelope.error?.message ?? envelope.error?.code ?? "ok=false")
        }
        return result
    }

    private static func fetchWorktrees(_ runner: any OrcaCommandRunning, _ timeout: TimeInterval,
                                       environment: String? = nil) async throws -> [RawWorktree] {
        try await decode(runner, timeout, RawWorktreesResult.self,
                         ["worktree", "ps", "--json"] + environmentArguments(environment)).worktrees ?? []
    }

    /// All pages (`--cursor`); a failing page fails the source so a partial list never replaces the last good one.
    private static func fetchWorkers(_ runner: any OrcaCommandRunning, _ timeout: TimeInterval,
                                     environment: String? = nil) async throws -> [RawWorker] {
        var all: [RawWorker] = []
        var cursor: String?
        for _ in 0..<maxWorkerPages {
            var args = ["orchestration", "worker-list", "--json"] + environmentArguments(environment)
            if let cursor { args += ["--cursor", cursor] }
            let page = try await decode(runner, timeout, RawWorkersResult.self, args)
            all += page.workers ?? []
            guard page.page?.hasMore == true, let next = page.page?.nextCursor, next != cursor else { return all }
            cursor = next
        }
        return all
    }

    static func environmentArguments(_ environment: String?) -> [String] {
        environment.map { ["--environment", $0] } ?? []
    }

    private func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, OrcaCommandError> {
        do { return .success(try await body()) }
        catch let e as OrcaCommandError { return .failure(e) }
        catch { return .failure(.launchFailed(error.localizedDescription)) }
    }

    private func decode<R: Decodable>(_ type: R.Type, _ args: [String]) async throws -> R {
        try await Self.decode(runner, timeout, type, args)
    }

    private func fetchWorktrees() async throws -> [RawWorktree] {
        try await Self.fetchWorktrees(runner, timeout)
    }

    private func fetchRateLimits() async throws -> [String: RawRateLimit] {
        try await decode(RawAccountsResult.self, ["account", "list", "--json"]).rateLimits ?? [:]
    }

    private func fetchStatus() async throws -> RawStatusResult.Runtime {
        guard let runtime = try await decode(RawStatusResult.self, ["status", "--json"]).runtime else {
            throw OrcaCommandError.invalidOutput("no runtime")
        }
        return runtime
    }

    private func fetchWorkers() async throws -> [RawWorker] {
        try await Self.fetchWorkers(runner, timeout)
    }
}
