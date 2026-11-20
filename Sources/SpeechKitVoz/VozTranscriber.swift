#if !os(watchOS)
import Foundation
import Observation
import Synchronization

/// Loads and retains the on-device VOZ recognizer for completed audio files.
///
/// Keep one transcriber for the app, or for the feature that imports and records
/// audio. Start ``prepareInBackground()`` at launch so the one-time download and
/// Neural Engine specialization happen while the user is doing something else,
/// drive setup UI from ``modelState`` or ``stateUpdates``, then call
/// ``transcribeAudioFile(file:)`` for each completed recording.
///
/// ```swift
/// let voz = VozTranscriber()
/// voz.prepareInBackground()
/// // ...
/// try await voz.waitUntilReady()
/// let response = try await voz.transcribeAudioFile(file: recordingURL)
/// ```
///
/// Transcription never prepares the model implicitly. Preparation can take
/// minutes on a first download, so it stays an explicit step that your app can
/// show progress for.
@Observable
@MainActor
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public final class VozTranscriber {
    /// Where VOZ reads and stores its model.
    ///
    /// Assigning a different configuration releases the loaded model and returns
    /// ``modelState`` to ``VozModelState/unprepared``. Cached files stay on disk.
    public var configuration: VozConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            configurationSnapshot.set(configuration)
            backgroundPreparationTask?.cancel()
            backgroundPreparationTask = nil
            manager.configuration = configuration
        }
    }

    /// The current download, loading, or ready state of the in-memory model.
    public private(set) var modelState: VozModelState = .unprepared

    /// The latest model-download fraction, from `0` through `1`.
    public private(set) var downloadProgress: Double = 0

    /// A Boolean value indicating whether the model is resident and can transcribe.
    public var isReady: Bool {
        modelState == .ready
    }

    /// The current state followed by every subsequent change.
    ///
    /// Each access returns an independent stream that immediately yields the
    /// current ``modelState``, so a consumer that starts late still sees where
    /// the model is. Streams finish when the transcriber is deallocated.
    ///
    /// ```swift
    /// for await state in voz.stateUpdates {
    ///     switch state { /* drive setup UI */ }
    /// }
    /// ```
    public var stateUpdates: AsyncStream<VozModelState> {
        AsyncStream { continuation in
            let id = registerStateObserver(continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.removeStateObserver(id)
                }
            }
        }
    }

    @ObservationIgnored private let manager: VozModelManager
    @ObservationIgnored private let cacheProbe: any VozModelCacheProbing
    @ObservationIgnored private let configurationSnapshot: VozConfigurationSnapshot
    @ObservationIgnored private var stateObservers: [Int: AsyncStream<VozModelState>.Continuation] = [:]
    @ObservationIgnored private var nextObserverID = 0
    @ObservationIgnored private var backgroundPreparationTask: Task<Void, Never>?

    /// Creates a transcriber that uses VOZ's managed model cache by default.
    ///
    /// Creating a transcriber never touches the disk or the network. Call
    /// ``prepareInBackground()`` or ``prepare()`` to start the model lifecycle.
    public convenience init(configuration: VozConfiguration = VozConfiguration()) {
        self.init(
            configuration: configuration,
            manager: VozModelManager(configuration: configuration),
            cacheProbe: VozModelStoreCacheProbe()
        )
    }

    /// Creates a transcriber with a caller-supplied engine and cache probe, for tests.
    convenience init(
        configuration: VozConfiguration,
        engine: any VozEngine,
        cacheProbe: any VozModelCacheProbing = VozModelStoreCacheProbe()
    ) {
        self.init(
            configuration: configuration,
            manager: VozModelManager(configuration: configuration, engine: engine),
            cacheProbe: cacheProbe
        )
    }

    private init(
        configuration: VozConfiguration,
        manager: VozModelManager,
        cacheProbe: any VozModelCacheProbing
    ) {
        self.configuration = configuration
        self.configurationSnapshot = VozConfigurationSnapshot(configuration)
        self.manager = manager
        self.cacheProbe = cacheProbe
        manager.onChange = { [weak self] in
            self?.managerDidChange()
        }
    }

    // MARK: - Model files

    /// Whether a complete, verified model is already on disk for ``configuration``.
    ///
    /// Use this before showing a download prompt: a cached model still has to be
    /// loaded at launch, but it does not have to be fetched again.
    ///
    /// This verifies the cached manifest's recorded SHA-256 digests, so it reads
    /// every cached file rather than only checking that the files exist. It is
    /// far cheaper than loading the model, but it is not instant for a 337 MB
    /// cache. The method is `nonisolated`, so call it from a background task
    /// when you need to keep the main actor free:
    ///
    /// ```swift
    /// let cached = await Task.detached { voz.isModelCached() }.value
    /// ```
    ///
    /// - Returns: `true` when no download is needed.
    public nonisolated func isModelCached() -> Bool {
        cacheProbe.isModelCached(configuration: configurationSnapshot.value)
    }

    // MARK: - Lifecycle

    /// Fetches the model files if they are missing, without loading the model.
    ///
    /// Use this for an onboarding download step. ``modelState`` returns to
    /// ``VozModelState/unprepared`` when the download finishes, because nothing
    /// is resident in memory yet.
    public func downloadIfNeeded() async throws {
        try await manager.prepare(.download)
    }

    /// Loads the model into memory, downloading the files first when they are missing.
    ///
    /// This is the per-launch cost. A first load after a download also pays a
    /// one-time Neural Engine specialization.
    public func load() async throws {
        try await manager.prepare(.load)
    }

    /// Downloads the model if needed and then loads it.
    ///
    /// Concurrent callers share one operation. Cancelling one caller does not
    /// stop the shared work; call ``release()`` to discard the lifecycle.
    public func prepare() async throws {
        try await manager.prepare(.load)
    }

    /// Starts ``prepare()`` without waiting for it, and reports failures through ``modelState``.
    ///
    /// Safe to call from app launch. While a background preparation is in
    /// flight this returns the existing task instead of starting a second one.
    /// A failure leaves ``modelState`` at ``VozModelState/failed(message:)``
    /// rather than throwing.
    ///
    /// - Returns: The task running the preparation.
    @discardableResult
    public func prepareInBackground() -> Task<Void, Never> {
        if let backgroundPreparationTask {
            return backgroundPreparationTask
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.backgroundPreparationTask = nil }
            // `prepare()` records the failure in `modelState`; a background
            // caller has nowhere to rethrow it.
            try? await self.prepare()
        }
        backgroundPreparationTask = task
        return task
    }

    /// Suspends until the model is ready, starting preparation when none is in flight.
    ///
    /// Call this immediately before the first transcription so a launch-time
    /// ``prepareInBackground()`` has a chance to finish first.
    ///
    /// - Throws: ``VozError/loadFailed(_:)`` when the model is already in the
    ///   ``VozModelState/failed(message:)`` state, or the underlying error when
    ///   the preparation this call waits on fails.
    public func waitUntilReady() async throws {
        if case .ready = modelState { return }
        if case .failed(let message) = modelState {
            throw VozError.loadFailed(message)
        }

        try await prepare()

        if case .failed(let message) = modelState {
            throw VozError.loadFailed(message)
        }
    }

    /// Drops the in-memory model and returns to ``VozModelState/unprepared``.
    ///
    /// Cached model files stay on disk and are reused by the next preparation.
    /// VOZ inference is noninterruptible while it is running, so a transcription
    /// already inside the recognizer finishes before its resources are freed;
    /// its result is rejected with ``VozError/releasedDuringTranscription``.
    public func release() {
        backgroundPreparationTask?.cancel()
        backgroundPreparationTask = nil
        manager.release()
    }

    // MARK: - Transcription

    /// Transcribes a completed local audio file with the prepared model.
    ///
    /// - Parameter file: A readable local audio-file URL.
    /// - Returns: The transcript, word timestamps, and processing metrics.
    /// - Throws: ``VozError/notPrepared`` when the model is not ready. This does
    ///   not prepare the model for you.
    public func transcribeAudioFile(file: URL) async throws -> VozFileTranscriptionResponse {
        try await manager.transcribe(file: file)
    }

    /// Transcribes a security-scoped local audio file with the prepared model.
    ///
    /// - Parameter securityScopedURL: A security-scoped file URL from an open
    ///   panel, document picker, or drag-and-drop handoff.
    /// - Returns: The transcript, word timestamps, and processing metrics.
    public func transcribeAudioFile(
        securityScopedURL: URL
    ) async throws -> VozFileTranscriptionResponse {
        guard securityScopedURL.startAccessingSecurityScopedResource() else {
            throw VozError.transcriptionFailed("Failed to access security-scoped resource.")
        }
        defer { securityScopedURL.stopAccessingSecurityScopedResource() }
        return try await transcribeAudioFile(file: securityScopedURL)
    }

    // MARK: - Private

    /// Waits for work retired by ``release()`` to finish, for tests.
    func waitForRelease() async {
        await manager.waitForRelease()
    }

    private func managerDidChange() {
        let state = manager.modelState
        let progress = manager.downloadProgress
        if downloadProgress != progress {
            downloadProgress = progress
        }
        guard modelState != state else { return }
        modelState = state
        for continuation in stateObservers.values {
            continuation.yield(state)
        }
    }

    private func registerStateObserver(
        _ continuation: AsyncStream<VozModelState>.Continuation
    ) -> Int {
        let id = nextObserverID
        nextObserverID &+= 1
        stateObservers[id] = continuation
        continuation.yield(modelState)
        return id
    }

    private func removeStateObserver(_ id: Int) {
        stateObservers[id] = nil
    }
}

/// A configuration copy readable from any isolation domain.
///
/// ``VozTranscriber/isModelCached()`` is `nonisolated` so callers can run its
/// digest check off the main actor; it needs the current configuration without
/// hopping back.
private final class VozConfigurationSnapshot: Sendable {
    private let storage: Mutex<VozConfiguration>

    init(_ configuration: VozConfiguration) {
        self.storage = Mutex(configuration)
    }

    var value: VozConfiguration {
        storage.withLock { $0 }
    }

    func set(_ configuration: VozConfiguration) {
        storage.withLock { $0 = configuration }
    }
}
#endif
