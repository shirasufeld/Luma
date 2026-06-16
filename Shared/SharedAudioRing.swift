import Darwin
import Foundation
import Synchronization

/// A single-producer/single-consumer byte ring in a memory-mapped App Group
/// file, used to hand PCM audio from the broadcast-upload extension (the one
/// writer) to the main app (the one reader) across process boundaries.
///
/// Concurrency contract: at most one writer process and one reader process. The
/// writer only advances `writeIndex`; the reader only advances `readIndex`.
/// Both indices live in the shared mapping as `Atomic<UInt64>`; the writer
/// publishes with a release store and the reader observes with an acquire load
/// (and vice versa for free space), so a peer never sees an index that runs
/// ahead of the bytes it refers to and 64-bit values never tear.
///
/// Indices are monotonic byte counters; the live span is `write - read` and
/// each maps into the ring at `index % capacity`. If the writer laps the reader
/// (overflow), the reader drops the oldest bytes and resynchronises —
/// acceptable for live captions where freshness beats completeness.
///
/// `nonisolated` because it is used both from the broadcast extension's
/// background callbacks and from `BroadcastAudioProvider`'s actor, neither of
/// which is the main actor that the app target defaults to. `@unchecked
/// Sendable` under the SPSC contract above: the writer and reader run on
/// different threads/processes by design, the atomic cursors order their
/// access, and lifecycle (`close`) is driven by the single owner.
nonisolated final class SharedAudioRing: @unchecked Sendable {
    enum RingError: Error { case openFailed, mapFailed, badHeader }

    private static let magic: UInt32 = 0x4C4D_4152  // "LMAR"
    private static let version: UInt32 = 1
    private static let headerSize = 64
    // Header field byte offsets; the two indices are 8-byte aligned for atomics.
    private static let offMagic = 0
    private static let offVersion = 4
    private static let offCapacity = 8
    private static let offWrite = 32
    private static let offRead = 40

    private let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let mappedSize: Int
    private var closed = false

    /// Ring data capacity in bytes (excludes the header).
    let capacity: Int

    /// Opens (or, when `create`, creates and zeroes) the ring at `url`.
    init(url: URL, capacityBytes: Int, create: Bool) throws {
        let total = Self.headerSize + capacityBytes
        let openFlags = create ? (O_CREAT | O_RDWR) : O_RDWR
        let fd = open(url.path, openFlags, 0o644)
        guard fd >= 0 else { throw RingError.openFailed }

        if create, ftruncate(fd, off_t(total)) != 0 {
            Darwin.close(fd)
            throw RingError.openFailed
        }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) >= Self.headerSize else {
            Darwin.close(fd)
            throw RingError.badHeader
        }
        let size = create ? total : Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            mapped != MAP_FAILED
        else {
            Darwin.close(fd)
            throw RingError.mapFailed
        }

        self.fd = fd
        self.base = mapped
        self.mappedSize = size

        if create {
            mapped.storeBytes(of: Self.magic, toByteOffset: Self.offMagic, as: UInt32.self)
            mapped.storeBytes(of: Self.version, toByteOffset: Self.offVersion, as: UInt32.self)
            mapped.storeBytes(of: UInt64(capacityBytes), toByteOffset: Self.offCapacity, as: UInt64.self)
            self.capacity = capacityBytes
            writeCursor.pointee.store(0, ordering: .relaxed)
            readCursor.pointee.store(0, ordering: .relaxed)
        } else {
            guard mapped.load(fromByteOffset: Self.offMagic, as: UInt32.self) == Self.magic else {
                munmap(mapped, size)
                Darwin.close(fd)
                throw RingError.badHeader
            }
            self.capacity = Int(mapped.load(fromByteOffset: Self.offCapacity, as: UInt64.self))
        }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        munmap(base, mappedSize)
        Darwin.close(fd)
    }

    /// Appends `src` if it fits whole; otherwise drops it to keep frame
    /// alignment (the next chunk lands cleanly). Returns bytes written.
    @discardableResult
    func write(_ src: UnsafeRawBufferPointer) -> Int {
        guard !closed, let srcBase = src.baseAddress else { return 0 }
        let count = src.count
        guard count > 0, count <= capacity else { return 0 }

        let write = writeCursor.pointee.load(ordering: .relaxed)  // sole writer
        let read = readCursor.pointee.load(ordering: .acquiring)  // observe consumer progress
        let free = capacity - Int(write &- read)
        guard count <= free else { return 0 }

        let data = base.advanced(by: Self.headerSize)
        let pos = Int(write % UInt64(capacity))
        let firstChunk = min(count, capacity - pos)
        memcpy(data.advanced(by: pos), srcBase, firstChunk)
        if firstChunk < count {
            memcpy(data, srcBase.advanced(by: firstChunk), count - firstChunk)
        }
        // Release: the payload copy is visible before the index advances.
        writeCursor.pointee.store(write &+ UInt64(count), ordering: .releasing)
        return count
    }

    /// Drains all available bytes into `out`. Returns the byte count.
    @discardableResult
    func read(into out: inout Data) -> Int {
        guard !closed else { return 0 }
        let write = writeCursor.pointee.load(ordering: .acquiring)  // acquire the published payload
        let read = readCursor.pointee.load(ordering: .relaxed)  // sole reader

        var available = Int(write &- read)
        guard available > 0 else { return 0 }
        // Writer lapped us: drop the oldest bytes and resync to one capacity back.
        let start = available > capacity ? write &- UInt64(capacity) : read
        if available > capacity { available = capacity }

        let data = base.advanced(by: Self.headerSize)
        let pos = Int(start % UInt64(capacity))
        out.removeAll(keepingCapacity: true)
        let firstChunk = min(available, capacity - pos)
        out.append(
            data.advanced(by: pos).assumingMemoryBound(to: UInt8.self), count: firstChunk)
        if firstChunk < available {
            out.append(data.assumingMemoryBound(to: UInt8.self), count: available - firstChunk)
        }
        // Release: the payload is fully read before the read index advances.
        readCursor.pointee.store(write, ordering: .releasing)
        return available
    }

    // Cross-process atomic cursors living in the shared mapping.
    private var writeCursor: UnsafeMutablePointer<Atomic<UInt64>> {
        base.advanced(by: Self.offWrite).assumingMemoryBound(to: Atomic<UInt64>.self)
    }
    private var readCursor: UnsafeMutablePointer<Atomic<UInt64>> {
        base.advanced(by: Self.offRead).assumingMemoryBound(to: Atomic<UInt64>.self)
    }
}
