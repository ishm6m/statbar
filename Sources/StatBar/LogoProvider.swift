import AppKit
import SwiftUI

// MARK: - Descriptor

/// What kind of logo a request resolves to. Each kind maps to a different
/// remote source and on-disk namespace.
enum LogoKind: String, Sendable {
    case team
    case league
}

/// Stable, hashable identity for one logo. `id` is the caller-supplied stable
/// identifier (team abbreviation or league id). `sport` is only needed for
/// team logos, whose remote URL is league-scoped on ESPN's CDN.
struct LogoDescriptor: Hashable, Sendable {
    let kind: LogoKind
    let id: String
    let sport: Sport?
    /// League id (e.g. "eng.1") for team logos. Part of identity and the cache
    /// key so the same abbreviation in two leagues that share one sport category
    /// never collides — all soccer leagues have `sport == .soccer`, so without
    /// this Monaco (fra.1) and Monza (ita.1), both abbreviated "MON", would map
    /// to one cache entry and show each other's crest. Nil for non-team logos and
    /// legacy callers, where the key falls back to the sport scope (single-league
    /// sports like NFL/NBA/NHL/MLB have league id == sport raw value, so their
    /// keys are unchanged either way).
    let league: String?
    /// Explicit logo URL, preferred over the derived one when present. Excluded
    /// from identity (below) so it never affects the cache key or handle dedup —
    /// it's only an alternate source for the same logo.
    let overrideURL: String?

    init(kind: LogoKind, id: String, sport: Sport? = nil, league: String? = nil, overrideURL: String? = nil) {
        self.kind = kind
        self.id = id
        self.sport = sport
        self.league = league
        self.overrideURL = overrideURL
    }

    // Identity is (kind, id, sport, league) only — the override is just a source
    // hint, so it stays out of identity and the cache key.
    static func == (lhs: LogoDescriptor, rhs: LogoDescriptor) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id && lhs.sport == rhs.sport && lhs.league == rhs.league
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
        hasher.combine(sport)
        hasher.combine(league)
    }

    /// Filesystem-safe cache key, unique across kinds and (for teams) leagues so
    /// the same abbreviation in two leagues never collides. Scope is the league
    /// id when known, else the sport raw value (back-compat for callers without a
    /// league, e.g. the followed-team catalog).
    var cacheKey: String {
        let scope = league.map { "\($0)-" } ?? sport.map { "\($0.rawValue)-" } ?? ""
        let safe = id.lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(kind.rawValue)-\(scope)\(safe)"
    }

    /// Remote source for this logo, or nil when it can't be resolved (e.g. a
    /// team logo with no sport context).
    var remoteURL: URL? {
        switch kind {
        case .team:
            if let overrideURL, let url = URL(string: overrideURL) { return url }
            guard sport != nil, !id.isEmpty else { return nil }
            return URL(string: "https://a.espncdn.com/i/teamlogos/\(LeagueDefinition.espnSportSlug)/500/\(id.lowercased()).png")
        case .league:
            guard !id.isEmpty else { return nil }
            return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(id.lowercased()).png")
        }
    }
}

// MARK: - Diagnostics

/// Hidden-panel counters for the logo subsystem. Lives on the main actor so the
/// Settings debug view observes it directly; the store reports outcomes here.
@MainActor
final class LogoDiagnostics: ObservableObject {
    static let shared = LogoDiagnostics()

    @Published private(set) var memoryHits = 0
    @Published private(set) var diskHits = 0
    @Published private(set) var downloads = 0
    @Published private(set) var failures = 0
    @Published private(set) var cachedCount = 0

    private init() {}

    func recordMemoryHit() { memoryHits += 1 }
    func recordDiskHit() { diskHits += 1 }
    func recordDownload() { downloads += 1 }
    func recordFailure() { failures += 1 }
    func setCachedCount(_ n: Int) { cachedCount = n }
}

// MARK: - UI handle

/// One observable image slot for a descriptor. Views hold this; when the real
/// logo arrives the provider flips `image` on the main actor and SwiftUI
/// re-renders automatically. `resolved` stays false after a failure so a later
/// request retries.
@MainActor
final class LogoHandle: ObservableObject {
    let descriptor: LogoDescriptor
    @Published fileprivate(set) var image: NSImage
    /// True once real artwork has loaded. While false, views draw the monogram
    /// avatar instead of the placeholder image — so loading states stay legible.
    @Published fileprivate(set) var hasImage = false
    fileprivate var resolved = false

    init(descriptor: LogoDescriptor, placeholder: NSImage) {
        self.descriptor = descriptor
        self.image = placeholder
    }
}

// MARK: - Provider

/// Lazy, cache-first logo loader. Lookup order: in-memory NSCache → disk cache →
/// remote download → placeholder. Disk files are PNG with a 30-day TTL; stale
/// files are served immediately and refreshed in the background. The heavy
/// lifting (disk I/O, downloads, dedup, concurrency limit) lives in `LogoStore`,
/// an actor, and never blocks the main thread. This façade owns the main-actor
/// pieces: the NSImage memory cache, the shared handles, and the placeholder.
@MainActor
final class LogoProvider {
    static let shared = LogoProvider()

    private let store = LogoStore()
    private let memory = NSCache<NSString, NSImage>()
    private var handles: [LogoDescriptor: LogoHandle] = [:]

    /// Neutral stand-in shown until (or unless) a real logo loads.
    private lazy var placeholder: NSImage = {
        let symbol = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Logo")
            ?? NSImage(size: NSSize(width: 32, height: 32))
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        image.isTemplate = true
        return image
    }()

    private init() {
        memory.countLimit = 256
        Task { await refreshCachedCount() }
    }

    // MARK: Public API

    func logo(forTeamID id: String, sport: Sport, league: String? = nil, overrideURL: String? = nil) -> LogoHandle {
        handle(for: LogoDescriptor(kind: .team, id: id, sport: sport, league: league, overrideURL: overrideURL))
    }

    func logo(forLeagueID id: String) -> LogoHandle {
        handle(for: LogoDescriptor(kind: .league, id: id))
    }

    /// Synchronous in-memory lookup for callers that can't observe a `LogoHandle`
    /// (the menu bar builds a one-shot attributed string, not a SwiftUI view). It
    /// also kicks off resolution via `handle`, so a cold logo warms within a poll
    /// and the next render is a hit; returns nil until then so the caller can fall
    /// back to text instead of flashing the placeholder shield.
    func cachedImage(forTeamID id: String, sport: Sport, league: String? = nil, overrideURL: String? = nil) -> NSImage? {
        let descriptor = LogoDescriptor(kind: .team, id: id, sport: sport, league: league, overrideURL: overrideURL)
        _ = handle(for: descriptor)
        return memory.object(forKey: descriptor.cacheKey as NSString)
    }

    /// Warm the cache for every team in a freshly-downloaded scoreboard so the
    /// next popup open paints real artwork instantly. Uses the same descriptor
    /// identity the views resolve (`kind .team`, abbreviation, sport, official
    /// `logo` URL), so a warmed logo is a memory hit when its row appears. Pure
    /// fire-and-forget: each resolve runs off the main thread, downloads are
    /// coalesced in `LogoStore`, and nothing here blocks rendering.
    func prefetch(_ matches: [Match]) {
        for match in matches {
            _ = handle(for: LogoDescriptor(
                kind: .team, id: match.homeTeam, sport: match.sport, league: match.league, overrideURL: match.homeLogo
            ))
            _ = handle(for: LogoDescriptor(
                kind: .team, id: match.awayTeam, sport: match.sport, league: match.league, overrideURL: match.awayLogo
            ))
        }
    }

    // MARK: Resolution

    private func handle(for descriptor: LogoDescriptor) -> LogoHandle {
        let handle: LogoHandle
        if let existing = handles[descriptor] {
            handle = existing
        } else {
            handle = LogoHandle(descriptor: descriptor, placeholder: placeholder)
            handles[descriptor] = handle
        }

        // Memory cache: synchronous, instant, no work scheduled.
        if let cached = memory.object(forKey: descriptor.cacheKey as NSString) {
            if !handle.resolved {
                handle.image = cached
                handle.hasImage = true
                handle.resolved = true
            }
            LogoDiagnostics.shared.recordMemoryHit()
            return handle
        }

        // Not in memory and not yet resolved (fresh, or retrying after failure):
        // resolve off the main thread.
        if !handle.resolved {
            resolve(handle)
        }
        return handle
    }

    private func resolve(_ handle: LogoHandle) {
        let descriptor = handle.descriptor
        Task { [weak self, weak handle] in
            guard let self else { return }
            let result = await self.store.load(descriptor)
            guard let handle else { return }

            switch result {
            case let .disk(data, stale):
                self.apply(data, to: handle, cache: true)
                LogoDiagnostics.shared.recordDiskHit()
                if stale { self.backgroundRefresh(handle) }
            case let .downloaded(data):
                self.apply(data, to: handle, cache: true)
                LogoDiagnostics.shared.recordDownload()
                await self.refreshCachedCount()
            case .failed:
                // Keep the placeholder; leave `resolved` false so a later
                // request retries the download.
                LogoDiagnostics.shared.recordFailure()
            }
        }
    }

    /// Re-download a stale-but-valid logo without disturbing the visible image
    /// until fresh bytes land.
    private func backgroundRefresh(_ handle: LogoHandle) {
        let descriptor = handle.descriptor
        Task { [weak self, weak handle] in
            guard let self else { return }
            guard let data = await self.store.refresh(descriptor) else { return }
            guard let handle else { return }
            self.apply(data, to: handle, cache: true)
            LogoDiagnostics.shared.recordDownload()
            await self.refreshCachedCount()
        }
    }

    /// Decode bytes into an NSImage on the main actor (NSImage isn't Sendable,
    /// so it never crosses the actor boundary) and publish it.
    private func apply(_ data: Data, to handle: LogoHandle, cache: Bool) {
        guard let image = NSImage(data: data) else {
            LogoDiagnostics.shared.recordFailure()
            return
        }
        if cache {
            memory.setObject(image, forKey: handle.descriptor.cacheKey as NSString)
        }
        handle.image = image
        handle.hasImage = true
        handle.resolved = true
    }

    private func refreshCachedCount() async {
        let count = await store.cachedFileCount()
        LogoDiagnostics.shared.setCachedCount(count)
    }
}

// MARK: - Store (off-main actor)

/// The outcome of a cache-first load. All cases carry `Data` (Sendable); the
/// NSImage is built later on the main actor.
private enum LogoLoadResult: Sendable {
    case disk(Data, stale: Bool)
    case downloaded(Data)
    case failed
}

/// Owns disk cache, downloads, request coalescing, the concurrency limit, and
/// the TTL. An actor, so every byte of this work happens off the main thread and
/// its mutable state (the in-flight table) is race-free.
private actor LogoStore {
    /// 30-day freshness window. Older files still display but trigger a
    /// background refresh.
    private static let ttl: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let session: URLSession
    private let gate = AsyncSemaphore(limit: 4)

    /// Coalescing: one shared download Task per cache key so concurrent callers
    /// never fetch the same logo twice.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("StatBar/Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: Load

    func load(_ descriptor: LogoDescriptor) async -> LogoLoadResult {
        let url = fileURL(for: descriptor)

        // 1. Disk cache. A file is stale (serve now, refresh in the background)
        // when it has aged past the TTL OR when the source `logo` URL has changed
        // since it was cached — so an updated crest replaces the old one without
        // a blank frame.
        if let data = try? Data(contentsOf: url) {
            let stale = isStale(url) || urlChanged(descriptor)
            return .disk(data, stale: stale)
        }

        // 2. Remote.
        if let data = await download(descriptor) {
            return .downloaded(data)
        }
        return .failed
    }

    /// Force a fresh download (used for stale-while-revalidate). Returns the new
    /// bytes, or nil if the network fetch failed.
    func refresh(_ descriptor: LogoDescriptor) async -> Data? {
        await download(descriptor)
    }

    func cachedFileCount() -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents?.filter { $0.pathExtension == "png" }.count ?? 0
    }

    // MARK: Download + coalescing

    private func download(_ descriptor: LogoDescriptor) async -> Data? {
        let key = descriptor.cacheKey

        if let existing = inFlight[key] {
            return await existing.value
        }

        guard let remote = descriptor.remoteURL else { return nil }
        let destination = fileURL(for: descriptor)
        let sidecar = urlSidecar(for: descriptor)

        let task = Task<Data?, Never> { [session, gate] in
            await gate.wait()
            defer { Task { await gate.signal() } }
            do {
                let (data, response) = try await session.data(from: remote)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let png = Self.pngData(from: data) else {
                    return nil
                }
                try? png.write(to: destination, options: .atomic)
                // Record the source URL so a later URL change invalidates this
                // file even before the TTL expires.
                try? Data(remote.absoluteString.utf8).write(to: sidecar, options: .atomic)
                return png
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        return data
    }

    // MARK: Helpers

    private func fileURL(for descriptor: LogoDescriptor) -> URL {
        directory.appendingPathComponent("\(descriptor.cacheKey).png")
    }

    /// Companion file holding the source URL the cached PNG was fetched from.
    private func urlSidecar(for descriptor: LogoDescriptor) -> URL {
        directory.appendingPathComponent("\(descriptor.cacheKey).url")
    }

    /// True when the descriptor now resolves to a different remote URL than the
    /// cached file was fetched from. A missing sidecar (logo cached before this
    /// existed, or a descriptor with no resolvable URL) reports false so legacy
    /// caches aren't needlessly refetched — the TTL still bounds their age.
    private func urlChanged(_ descriptor: LogoDescriptor) -> Bool {
        guard let current = descriptor.remoteURL?.absoluteString,
              let recorded = try? String(contentsOf: urlSidecar(for: descriptor), encoding: .utf8)
        else { return false }
        return current != recorded
    }

    private func isStale(_ url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attrs?[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > Self.ttl
    }

    /// Normalize downloaded bytes to PNG so the disk cache is always PNG, even
    /// when a source serves another format.
    private static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return data }
        return rep.representation(using: .png, properties: [:]) ?? data
    }
}

// MARK: - Concurrency gate

/// Minimal async counting semaphore — caps concurrent downloads without
/// blocking a thread.
private actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

// MARK: - Monogram avatar

/// Derive a 1–2 letter monogram from a display name. Multi-word names use the
/// first letter of the first two words ("Kansas City Chiefs" → "KC"); single
/// words / abbreviations use their first two characters ("Arsenal" → "AR",
/// "KC" → "KC").
func logoMonogram(from name: String) -> String {
    let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
    if words.count >= 2 {
        let a = words[0].first.map(String.init) ?? ""
        let b = words[1].first.map(String.init) ?? ""
        return (a + b).uppercased()
    }
    return String(name.prefix(2)).uppercased()
}

/// Tasteful, consistent letter-avatar shown when no real logo is available
/// (or while one loads). Color is deterministic per text so a given team always
/// gets the same tint, and the circle frame matches the logo frame so swapping
/// to real artwork causes no layout shift.
struct MonogramAvatar: View {
    let text: String
    let size: CGFloat

    /// Muted, dark-mode-friendly palette. Index is chosen deterministically from
    /// the text so the same name is always the same color.
    private static let palette: [Color] = [
        .blue, .indigo, .teal, .green, .orange, .pink, .purple, .red, .mint, .cyan,
    ]

    private var tint: Color {
        guard !text.isEmpty else { return .gray }
        let sum = text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            Circle()
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            Text(text)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - SwiftUI view

/// Drop-in logo image that loads lazily and updates itself the moment the real
/// artwork arrives. Until then (and on failure) it shows a `MonogramAvatar`
/// derived from `label`, so the slot is always legible and never shifts layout.
/// All variants carry an accessibility label.
struct LogoView: View {
    @StateObject private var handle: LogoHandle
    private let size: CGFloat
    private let label: String
    private let monogram: String

    init(teamID: String, sport: Sport, league: String? = nil, label: String? = nil, size: CGFloat = 20, overrideURL: String? = nil) {
        _handle = StateObject(wrappedValue: LogoProvider.shared.logo(forTeamID: teamID, sport: sport, league: league, overrideURL: overrideURL))
        self.size = size
        let resolved = label ?? teamID
        self.label = resolved
        self.monogram = logoMonogram(from: resolved)
    }

    /// Resolve a catalog `Team`'s logo via its abbreviation (+ optional URL
    /// override), labeling and monogramming from its display name.
    init(team: Team, size: CGFloat = 20) {
        _handle = StateObject(wrappedValue: LogoProvider.shared.logo(
            forTeamID: team.abbreviation, sport: team.sport, overrideURL: team.logoURLOverride
        ))
        self.size = size
        self.label = team.name
        self.monogram = logoMonogram(from: team.name)
    }

    init(leagueID: String, label: String? = nil, size: CGFloat = 20) {
        _handle = StateObject(wrappedValue: LogoProvider.shared.logo(forLeagueID: leagueID))
        self.size = size
        let resolved = label ?? leagueID
        self.label = resolved
        self.monogram = logoMonogram(from: resolved)
    }

    var body: some View {
        Group {
            if handle.hasImage {
                Image(nsImage: handle.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                MonogramAvatar(text: monogram, size: size)
            }
        }
        .accessibilityLabel(Text("\(label) logo"))
    }
}
