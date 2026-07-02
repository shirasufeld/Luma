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
/// each maps into the ring at `index % capacity`. `write` refuses chunks that
/// don't fit, so a healthy writer never laps the reader; the reader still
/// defends against a span wider than the ring (cursor history left behind by
/// an earlier session racing a live writer) by dropping the oldest bytes and
/// resynchronising — acceptable for live captions where freshness beats
/// completeness.
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

    /// Opens the ring at `url`.
    ///
    /// `create: true` (the consumer) readies the ring for a fresh session: a
    /// missing or invalid file is (re)initialised in place, while an existing
    /// valid ring keeps its header and monotonic cursors and only fast-forwards
    /// `readIndex` to `writeIndex`, discarding any stale backlog. Reusing the
    /// same inode matters: the producer may already have the file mmapped, and
    /// unlinking/recreating it would strand that mapping on an orphaned inode
    /// (its writes would silently go nowhere).
    ///
    /// `create: false` (the producer) opens an existing ring, validating the
    /// header before trusting it.
    init(url: URL, capacityBytes: Int, create: Bool) throws {
        let openFlags = create ? (O_CREAT | O_RDWR) : O_RDWR
        let fd = open(url.path, openFlags, 0o644)
        guard fd >= 0 else { throw RingError.openFailed }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            Darwin.close(fd)
            throw RingError.openFailed
        }

        if create {
            let total = Self.headerSize + capacityBytes
            // A wrong-sized file can't be a valid ring for this capacity;
            // resize it (fresh zero-byte files land here too).
            let hadExpectedSize = Int(info.st_size) == total
            if !hadExpectedSize, ftruncate(fd, off_t(total)) != 0 {
                Darwin.close(fd)
                throw RingError.openFailed
            }
            guard let mapped = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                mapped != MAP_FAILED
            else {
                Darwin.close(fd)
                throw RingError.mapFailed
            }
            self.fd = fd
            self.base = mapped
            self.mappedSize = total
            self.capacity = capacityBytes

            let headerValid =
                hadExpectedSize
                && mapped.load(fromByteOffset: Self.offMagic, as: UInt32.self) == Self.magic
                && mapped.load(fromByteOffset: Self.offVersion, as: UInt32.self) == Self.version
                && mapped.load(fromByteOffset: Self.offCapacity, as: UInt64.self)
                    == UInt64(capacityBytes)
            if headerValid {
                // Keep the producer's cursors monotonic (it may be writing
                // right now); just drop whatever predates this session.
                let write = writeCursor.pointee.load(ordering: .acquiring)
                readCursor.pointee.store(write, ordering: .releasing)
            } else {
                mapped.storeBytes(of: Self.magic, toByteOffset: Self.offMagic, as: UInt32.self)
                mapped.storeBytes(
                    of: Self.version, toByteOffset: Self.offVersion, as: UInt32.self)
                mapped.storeBytes(
                    of: UInt64(capacityBytes), toByteOffset: Self.offCapacity, as: UInt64.self)
                writeCursor.pointee.store(0, ordering: .relaxed)
                readCursor.pointee.store(0, ordering: .relaxed)
            }
        } else {
            let size = Int(info.st_size)
            guard size >= Self.headerSize else {
                Darwin.close(fd)
                throw RingError.badHeader
            }
            guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                mapped != MAP_FAILED
            else {
                Darwin.close(fd)
                throw RingError.mapFailed
            }
            // Trust nothing until the header checks out: a torn/truncated file
            // must not send reads or writes past the end of the mapping.
            let declaredCapacity = mapped.load(
                fromByteOffset: Self.offCapacity, as: UInt64.self)
            guard mapped.load(fromByteOffset: Self.offMagic, as: UInt32.self) == Self.magic,
                mapped.load(fromByteOffset: Self.offVersion, as: UInt32.self) == Self.version,
                declaredCapacity > 0, declaredCapacity <= UInt64(size - Self.headerSize)
            else {
                munmap(mapped, size)
                Darwin.close(fd)
                throw RingError.badHeader
            }
            self.fd = fd
            self.base = mapped
            self.mappedSize = size
            self.capacity = Int(declaredCapacity)
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

    // Cross-process atomic cursors living in the shared mapping. Overlaying
    // `Atomic<UInt64>` on mmapped bytes sidesteps Swift's formal init/bind
    // rules, but the type is a single 8-byte trivial storage and the offsets
    // are 8-byte aligned — exactly the layout the hardware atomics need.
    private var writeCursor: UnsafeMutablePointer<Atomic<UInt64>> {
        base.advanced(by: Self.offWrite).assumingMemoryBound(to: Atomic<UInt64>.self)
    }
    private var readCursor: UnsafeMutablePointer<Atomic<UInt64>> {
        base.advanced(by: Self.offRead).assumingMemoryBound(to: Atomic<UInt64>.self)
    }
}
