import Foundation
import Synchronization
import TNCore

/// The file primitives the package store is built on, and the ones the
/// library commits its sidecars and its moves through. Not every file API
/// goes through it: `LibraryStore` still reads, lists, copies and deletes
/// with `FileManager`.
///
/// A seam rather than a concrete type so a test can fail call N, truncate a
/// staged write, or discard a published file's bytes after its rename: the
/// three faults the commit protocol has to survive, and the third is the one
/// that tells a real barrier from a decorative one.
package protocol PackageFileSystem: Sendable {
    /// `mkdir`, idempotent: an existing directory is not an error.
    func createDirectory(_ url: URL) throws
    /// Write `data` to a new file at `temp` (`O_CREAT | O_EXCL`), issue the
    /// barrier on its descriptor, close. The bytes are ordered before any
    /// rename that follows on this file system.
    func stage(_ data: Data, at temp: URL) throws
    /// `rename(temp, final)`: atomic replacement.
    func publish(_ temp: URL, to final: URL) throws
    /// `renamex_np(staged, final, RENAME_EXCL)`: a file or a whole directory
    /// takes a name nothing holds, or fails with `EEXIST` and moves nothing.
    /// `publish` would replace an empty directory there.
    func publishExclusive(_ staged: URL, to final: URL) throws
    /// `fsync` on the directory so the renames it holds are durable.
    func syncDirectory(_ url: URL) throws
    func read(_ url: URL) throws -> Data
    func exists(_ url: URL) -> Bool
    func modificationTime(_ url: URL) throws -> Date
    /// File names directly inside `directory`, no recursion, no hidden files.
    func list(_ directory: URL) throws -> [String]
    /// `unlink`; a missing file is not an error.
    func remove(_ url: URL) throws
    /// Bytes available to this app on the volume holding `url`.
    func availableBytes(at url: URL) throws -> Int64
}

extension PackageFileSystem {
    package func tempURL(beside final: URL) -> URL {
        final.deletingLastPathComponent()
            .appendingPathComponent("\(PackageStore.tempPrefix)\(UUID().uuidString)-\(final.lastPathComponent)")
    }

    /// Stage, publish, sync: the commit sequence for a single file.
    /// `syncing: nil` is the disposable case (`view.json`).
    package func writeAtomically(_ data: Data, to final: URL, syncing directory: URL?) throws {
        let temp = tempURL(beside: final)
        do {
            try stage(data, at: temp)
            try publish(temp, to: final)
            if let directory { try syncDirectory(directory) }
        } catch {
            try? remove(temp)
            throw error
        }
    }
}

package struct FileSystemError: Error, Sendable, Equatable, CustomStringConvertible {
    package enum Operation: String, Sendable { case mkdir, open, write, barrier, close, rename, fsync, read, stat, list, unlink, statfs }
    package let operation: Operation
    package let path: String
    package let code: Int32

    package init(_ operation: Operation, _ path: String, code: Int32) {
        self.operation = operation
        self.path = path
        self.code = code
    }

    package var description: String {
        "\(operation.rawValue) \(path): \(String(cString: strerror(code))) (\(code))"
    }
}

/// The production file system.
package struct PosixFileSystem: PackageFileSystem {
    package init() {}

    package func createDirectory(_ url: URL) throws {
        let path = url.path
        if Darwin.mkdir(path, 0o755) == 0 { return }
        if errno == EEXIST { return }
        throw FileSystemError(.mkdir, path, code: errno)
    }

    package func stage(_ data: Data, at temp: URL) throws {
        let path = temp.path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileSystemError(.open, path, code: errno) }
        var closed = false
        defer { if !closed { _ = Darwin.close(fd) } }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FileSystemError(.write, path, code: errno)
                }
                offset += written
            }
        }

        // F_BARRIERFSYNC: everything written to this descriptor reaches media
        // before anything issued after the barrier. That ordering, not a full
        // device flush, is what the commit protocol needs, and it is what
        // makes a published name never precede its bytes. A file system that
        // does not support the barrier gets the stronger F_FULLFSYNC.
        if fcntl(fd, F_BARRIERFSYNC) != 0 {
            if errno == ENOTSUP || errno == EINVAL {
                if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                    throw FileSystemError(.barrier, path, code: errno)
                }
            } else {
                throw FileSystemError(.barrier, path, code: errno)
            }
        }

        closed = true
        if Darwin.close(fd) != 0 { throw FileSystemError(.close, path, code: errno) }
    }

    package func publish(_ temp: URL, to final: URL) throws {
        if Darwin.rename(temp.path, final.path) != 0 {
            throw FileSystemError(.rename, final.path, code: errno)
        }
    }

    package func publishExclusive(_ staged: URL, to final: URL) throws {
        if renamex_np(staged.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            throw FileSystemError(.rename, final.path, code: errno)
        }
    }

    package func syncDirectory(_ url: URL) throws {
        let path = url.path
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileSystemError(.open, path, code: errno) }
        defer { _ = Darwin.close(fd) }
        if fsync(fd) != 0 { throw FileSystemError(.fsync, path, code: errno) }
    }

    package func read(_ url: URL) throws -> Data {
        let path = url.path
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileSystemError(.read, path, code: errno) }
        defer { _ = Darwin.close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw FileSystemError(.stat, path, code: errno) }
        var data = Data(count: Int(info.st_size))
        var filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileSystemError(.read, path, code: errno)
            }
            if count == 0 { break }
            filled += count
        }
        if filled < data.count { data.removeSubrange(filled...) }
        return data
    }

    package func exists(_ url: URL) -> Bool {
        (try? Self.fileInfo(of: url)) != nil
    }

    package func modificationTime(_ url: URL) throws -> Date {
        let modified = try Self.fileInfo(of: url)
        return Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)
    }

    /// The file's modification time, or a throw if it does not exist.
    private static func fileInfo(of url: URL) throws -> timespec {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else { throw FileSystemError(.stat, url.path, code: errno) }
        return info.st_mtimespec
    }

    package func list(_ directory: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
        } catch let error as NSError {
            throw FileSystemError(.list, directory.path, code: Int32(truncatingIfNeeded: error.code))
        }
    }

    package func remove(_ url: URL) throws {
        if Darwin.unlink(url.path) == 0 { return }
        if errno == ENOENT { return }
        throw FileSystemError(.unlink, url.path, code: errno)
    }

    package func availableBytes(at url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch let error as NSError {
            throw FileSystemError(.statfs, url.path, code: Int32(truncatingIfNeeded: error.code))
        }
    }
}

#if DEBUG
/// A file system that fails on cue. Debug only; the tests are its only user.
///
/// Counters are per operation kind, so "fail the third stage" and "discard
/// the second publish" mean what they say regardless of interleaving.
package final class FaultingFileSystem: PackageFileSystem {
    package enum Fault: Sendable, Equatable {
        /// The Nth `stage` throws before writing anything.
        case failStage(nth: Int)
        /// The Nth `stage` writes only `bytes` bytes of its payload, then
        /// returns as if it succeeded: a torn write.
        case truncateStage(nth: Int, bytes: Int)
        /// The Nth `publish` or `publishExclusive` throws.
        case failPublish(nth: Int)
        /// The Nth `publish` succeeds and the file's bytes are then lost:
        /// the name reached the directory, the data never reached media. A
        /// `publishExclusive` counts toward N but moves a directory, whose
        /// files were each published before it, so it loses nothing.
        case discardAfterPublish(nth: Int)
        /// The Nth `syncDirectory` throws.
        case failSync(nth: Int)
        /// The volume reports no free space.
        case noSpace
    }

    package struct Counts: Sendable, Equatable {
        package var stages = 0
        package var publishes = 0
        package var syncs = 0
    }

    private let base: any PackageFileSystem
    private let state: Mutex<(faults: [Fault], counts: Counts)>

    package init(base: any PackageFileSystem = PosixFileSystem(), faults: [Fault]) {
        self.base = base
        self.state = Mutex((faults: faults, counts: Counts()))
    }

    package var counts: Counts { state.withLock { $0.counts } }

    package struct InjectedFault: Error, Sendable, Equatable {
        package let fault: Fault
    }

    package func createDirectory(_ url: URL) throws { try base.createDirectory(url) }

    package func stage(_ data: Data, at temp: URL) throws {
        let (nth, faults) = state.withLock { s -> (Int, [Fault]) in
            s.counts.stages += 1
            return (s.counts.stages, s.faults)
        }
        for fault in faults {
            switch fault {
            case .failStage(let n) where n == nth:
                throw InjectedFault(fault: fault)
            case .truncateStage(let n, let bytes) where n == nth:
                try base.stage(data.prefix(bytes), at: temp)
                return
            default:
                continue
            }
        }
        try base.stage(data, at: temp)
    }

    package func publish(_ temp: URL, to final: URL) throws {
        let (nth, faults) = state.withLock { s -> (Int, [Fault]) in
            s.counts.publishes += 1
            return (s.counts.publishes, s.faults)
        }
        for fault in faults {
            switch fault {
            case .failPublish(let n) where n == nth:
                throw InjectedFault(fault: fault)
            case .discardAfterPublish(let n) where n == nth:
                try base.publish(temp, to: final)
                // The name is published; the bytes are gone.
                let fd = Darwin.open(final.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
                if fd >= 0 { _ = Darwin.close(fd) }
                return
            default:
                continue
            }
        }
        try base.publish(temp, to: final)
    }

    package func publishExclusive(_ staged: URL, to final: URL) throws {
        let (nth, faults) = state.withLock { s -> (Int, [Fault]) in
            s.counts.publishes += 1
            return (s.counts.publishes, s.faults)
        }
        if faults.contains(.failPublish(nth: nth)) { throw InjectedFault(fault: .failPublish(nth: nth)) }
        try base.publishExclusive(staged, to: final)
    }

    package func syncDirectory(_ url: URL) throws {
        let (nth, faults) = state.withLock { s -> (Int, [Fault]) in
            s.counts.syncs += 1
            return (s.counts.syncs, s.faults)
        }
        if faults.contains(.failSync(nth: nth)) { throw InjectedFault(fault: .failSync(nth: nth)) }
        try base.syncDirectory(url)
    }

    package func read(_ url: URL) throws -> Data { try base.read(url) }
    package func exists(_ url: URL) -> Bool { base.exists(url) }
    package func modificationTime(_ url: URL) throws -> Date { try base.modificationTime(url) }
    package func list(_ directory: URL) throws -> [String] { try base.list(directory) }
    package func remove(_ url: URL) throws { try base.remove(url) }
    package func availableBytes(at url: URL) throws -> Int64 {
        if state.withLock({ $0.faults.contains(.noSpace) }) { return 0 }
        return try base.availableBytes(at: url)
    }
}
#endif
