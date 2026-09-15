#if !os(watchOS)
import Foundation
import ModelStore
import Voz

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Whether a complete verified VOZ model is already on disk.
///
/// This is a protocol so tests can answer the question without a real cache.
protocol VozModelCacheProbing: Sendable {
    func isModelCached(configuration: VozConfiguration) -> Bool
}

/// The production probe, backed by `ModelStore.isDownloaded`.
struct VozModelStoreCacheProbe: VozModelCacheProbing {
    func isModelCached(configuration: VozConfiguration) -> Bool {
        guard let directory = VozCachedModel.location(for: configuration) else { return false }
        return VozCachedModel.isValid(at: directory)
    }
}

/// Provides the VOZ ModelStore with a native streaming digest for cached files.
/// The SDK's default Apple filesystem uses a pure-Swift SHA-256 implementation;
/// on a Debug build, checking the 460 MB encoder can block preparation for
/// minutes before the first progress callback. All manifest parsing and cache
/// layout still come from ModelStore.
enum VozCachedModel {
    static func location(for configuration: VozConfiguration) -> URL? {
        let modelDirectory = configuration.modelDirectory
        let cacheRoot = configuration.cacheDirectory?.path
        let store = ModelStore(
            transport: FoundationTransport(),
            fileSystem: CryptoKitFileSystem(cacheRoot: cacheRoot)
        )
        let spec = ModelSpec(
            repo: VozModel.repo,
            revision: VozModel.revision,
            files: VozModel.files[.apple] ?? [],
            cacheDirectory: modelDirectory?.path
        )
        return URL(fileURLWithPath: store.location(of: spec))
    }

    static func isValid(at directory: URL, configuration: VozConfiguration? = nil) -> Bool {
        #if canImport(CryptoKit)
        let cacheRoot = configuration?.cacheDirectory?.path
        let store = ModelStore(
            transport: FoundationTransport(),
            fileSystem: CryptoKitFileSystem(cacheRoot: cacheRoot)
        )
        let spec = ModelSpec(
            repo: VozModel.repo,
            revision: VozModel.revision,
            files: VozModel.files[.apple] ?? [],
            cacheDirectory: directory.path
        )
        return store.isDownloaded(spec)
        #else
        return false
        #endif
    }
}

#if canImport(CryptoKit)
private struct CryptoKitFileSystem: FileSystem {
    private let base: FoundationFileSystem

    init(cacheRoot: String?) {
        self.base = FoundationFileSystem(cacheRoot: cacheRoot)
    }

    func exists(_ path: String) -> Bool { base.exists(path) }
    func size(_ path: String) -> Int64? { base.size(path) }
    func read(_ path: String) throws -> [UInt8] { try base.read(path) }
    func write(_ path: String, _ bytes: [UInt8]) throws { try base.write(path, bytes) }
    func makeDirectory(_ path: String) throws { try base.makeDirectory(path) }
    func move(_ from: String, to: String) throws { try base.move(from, to: to) }
    func remove(_ path: String) { base.remove(path) }
    func defaultCacheRoot() -> String { base.defaultCacheRoot() }
    func listDirectory(_ path: String) -> [String] { base.listDirectory(path) }

    func digest(_ path: String) throws -> (size: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var hasher = CryptoKit.SHA256()
        var size: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk: Data
            #if canImport(ObjectiveC)
            chunk = try autoreleasepool {
                try handle.read(upToCount: 1 << 20) ?? Data()
            }
            #else
            chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            #endif
            if chunk.isEmpty { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, digest)
    }
}
#endif
#endif
