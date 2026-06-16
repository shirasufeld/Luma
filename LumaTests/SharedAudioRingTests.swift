import Foundation
import Testing

@testable import Luma

/// Exercises the cross-process PCM ring buffer in a single process (one writer,
/// one reader) — the logic that does not need a device or the App Group.
struct SharedAudioRingTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ring-\(UUID().uuidString).bin")
    }

    @Test func writeThenReadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ring = try SharedAudioRing(url: url, capacityBytes: 64, create: true)
        defer { ring.close() }

        let payload = Array(UInt8(0)..<UInt8(16))
        let written = payload.withUnsafeBytes { ring.write($0) }
        #expect(written == 16)

        var out = Data()
        let read = ring.read(into: &out)
        #expect(read == 16)
        #expect(Array(out) == payload)

        // Fully drained.
        let again = ring.read(into: &out)
        #expect(again == 0)
    }

    @Test func dropsChunksThatDoNotFit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ring = try SharedAudioRing(url: url, capacityBytes: 16, create: true)
        defer { ring.close() }

        // Larger than the whole ring → dropped.
        let tooBig = [UInt8](repeating: 7, count: 17)
        #expect(tooBig.withUnsafeBytes { ring.write($0) } == 0)

        // Exactly fills the ring.
        let fits = [UInt8](repeating: 3, count: 16)
        #expect(fits.withUnsafeBytes { ring.write($0) } == 16)

        // No free space left → dropped, keeping frame alignment.
        let more = [UInt8](repeating: 9, count: 4)
        #expect(more.withUnsafeBytes { ring.write($0) } == 0)
    }

    @Test func wrapsAroundAcrossManyReadWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ring = try SharedAudioRing(url: url, capacityBytes: 16, create: true)
        defer { ring.close() }

        var out = Data()
        for index in 0..<200 {
            let chunk = [UInt8(index & 0xff), UInt8((index &* 2) & 0xff), UInt8((index &* 3) & 0xff)]
            #expect(chunk.withUnsafeBytes { ring.write($0) } == 3)
            let read = ring.read(into: &out)
            #expect(read == 3)
            #expect(Array(out) == chunk)
        }
    }

    @Test func partialDrainThenContinue() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ring = try SharedAudioRing(url: url, capacityBytes: 32, create: true)
        defer { ring.close() }

        let first = [UInt8](repeating: 1, count: 10)
        let second = [UInt8](repeating: 2, count: 10)
        #expect(first.withUnsafeBytes { ring.write($0) } == 10)
        #expect(second.withUnsafeBytes { ring.write($0) } == 10)

        // A single read drains everything currently available, in order.
        var out = Data()
        let read = ring.read(into: &out)
        #expect(read == 20)
        #expect(Array(out) == first + second)
    }

    @Test func reopenReadsHeaderCapacity() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let creator = try SharedAudioRing(url: url, capacityBytes: 128, create: true)
        creator.close()

        let opener = try SharedAudioRing(url: url, capacityBytes: 0, create: false)
        defer { opener.close() }
        #expect(opener.capacity == 128)
    }

    @Test func openMissingFileThrows() {
        let url = tempURL()
        #expect(throws: (any Error).self) {
            _ = try SharedAudioRing(url: url, capacityBytes: 64, create: false)
        }
    }

    /// Producer and consumer on separate threads: every byte must arrive in
    /// order with none lost — the cross-thread exercise of the atomic cursors
    /// that mirrors the real cross-process writer/reader.
    @Test func concurrentProducerConsumerPreservesOrder() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ring = try SharedAudioRing(url: url, capacityBytes: 4096, create: true)
        defer { ring.close() }

        let total = 60_000
        let producer = Thread {
            var sent = 0
            var chunk = [UInt8]()
            while sent < total {
                let n = min(128, total - sent)
                chunk.removeAll(keepingCapacity: true)
                for offset in 0..<n { chunk.append(UInt8((sent + offset) & 0xff)) }
                while chunk.withUnsafeBytes({ ring.write($0) }) == 0 {
                    // Ring momentarily full; spin until the consumer drains.
                }
                sent += n
            }
        }
        producer.start()

        var received = [UInt8]()
        received.reserveCapacity(total)
        var out = Data()
        let deadline = Date().addingTimeInterval(10)
        while received.count < total, Date() < deadline {
            if ring.read(into: &out) > 0 { received.append(contentsOf: out) }
        }

        #expect(received.count == total)
        var firstMismatch = -1
        for index in 0..<min(received.count, total) where received[index] != UInt8(index & 0xff) {
            firstMismatch = index
            break
        }
        #expect(firstMismatch == -1)
    }
}
