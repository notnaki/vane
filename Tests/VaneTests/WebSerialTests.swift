import Darwin
import os
import XCTest
@testable import vane

/// A pseudo-terminal standing in for a serial adapter: the port opens the slave by path,
/// the fixture plays the device on the master. No window, no hardware.
final class SerialPty: @unchecked Sendable {
    let master: Int32
    let path: String

    init() throws {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw POSIXError(.EIO) }
        var settings = termios()
        tcgetattr(slave, &settings)
        cfmakeraw(&settings)
        tcsetattr(slave, TCSANOW, &settings)
        // The port opens the slave by path, as it would a `/dev/cu.*` node. No descriptor is
        // kept here, so the master reads end-of-file exactly while nothing holds the slave:
        // that is how `slaveIsClosed` sees a port give its descriptor back. (A pty does not
        // enforce the port's exclusive lock, so a second open cannot show it.)
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.master = master
        path = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    deinit { Darwin.close(master) }

    var device: SerialDevice {
        SerialDevice(path: path, vendorID: 0x10c4, productID: 0xea60, product: "Fixture UART", serialNumber: "F1")
    }

    /// Whether every descriptor on the slave has gone. Takes whatever the port had sent.
    var slaveIsClosed: Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = Darwin.read(master, &chunk, chunk.count)
            if got <= 0 { return got == 0 }    // 0 is end-of-file; -1 is EAGAIN, a slave that is open and quiet
        }
    }

    /// Moves `count` bytes one way; `step` is given how many have gone and returns how many
    /// more did. It runs on a queue of its own and waits on the descriptor, not on a timer:
    /// a page can keep talking meanwhile, and a runner with coarse timers is not slowed to a
    /// kilobyte a tick. It gives up only when nothing has moved for ten seconds, because the
    /// other end of a transfer waits for all of it and slow must not be taken for stuck.
    private func move(_ count: Int, when events: Int32, _ step: @escaping @Sendable (Int) -> Int) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [master] in
                var moved = 0, progress = ContinuousClock.now
                while moved < count {
                    let more = step(moved)
                    if more > 0 { moved += more; progress = .now; continue }
                    guard ContinuousClock.now - progress < .seconds(10) else { return done.resume(throwing: POSIXError(.ETIMEDOUT)) }
                    var wait = pollfd(fd: master, events: Int16(events), revents: 0)
                    poll(&wait, 1, 2)
                }
                done.resume()
            }
        }
    }

    /// The device speaks.
    func send(_ bytes: [UInt8]) async throws {
        try await move(bytes.count, when: POLLOUT) { [master] offset in
            bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, $0.count - offset) }
        }
    }

    /// What the device heard.
    func receive(_ count: Int) async throws -> [UInt8] {
        nonisolated(unsafe) let heard = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
        defer { heard.deallocate() }
        try await move(count, when: POLLIN) { [master] offset in Darwin.read(master, heard.baseAddress! + offset, count - offset) }
        return Array(heard)
    }

    /// The device repeats everything back until `count` bytes have gone round.
    func echo(_ count: Int) {
        DispatchQueue.global().async { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            var echoed = 0
            let deadline = ContinuousClock.now + .seconds(20)
            while echoed < count, ContinuousClock.now < deadline {
                var wait = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&wait, 1, 50) > 0 else { continue }
                let got = Darwin.read(master, &chunk, chunk.count)
                guard got > 0 else { continue }
                var offset = 0
                while offset < got, ContinuousClock.now < deadline {
                    let sent = chunk.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, got - offset) }
                    if sent > 0 { offset += sent } else { usleep(500) }
                }
                echoed += got
            }
        }
    }
}

/// Validation, matching and the grant store: no device, no page.
@MainActor final class WebSerialTests: XCTestCase {
    private var profile = UUID()

    override func setUp() async throws {
        TestEnvironment.prepare()
        profile = UUID()
    }

    override func tearDown() async throws { WebSerial.forgetAll(profileID: profile) }

    private func typeError(_ work: @autoclosure () throws -> Any, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), message, file: file, line: line) {
            XCTAssertEqual(($0 as? SerialError)?.name, "TypeError", message, file: file, line: line)
        }
    }

    func testOpenOptionsTakeTheSpecDefaults() throws {
        let options = try SerialOptions(["baudRate": 115200])
        XCTAssertEqual(options.baudRate, 115200)
        XCTAssertEqual(options.dataBits, 8)
        XCTAssertEqual(options.stopBits, 1)
        XCTAssertEqual(options.parity, .none)
        XCTAssertEqual(options.bufferSize, 255)
        XCTAssertFalse(options.hardwareFlowControl)
        let full = try SerialOptions(["baudRate": 921600.0, "dataBits": 7, "stopBits": 2, "parity": "odd",
                                      "bufferSize": 4096, "flowControl": "hardware"])
        XCTAssertEqual(full.baudRate, 921600)
        XCTAssertEqual([full.dataBits, full.stopBits, full.bufferSize], [7, 2, 4096])
        XCTAssertEqual(full.parity, .odd)
        XCTAssertTrue(full.hardwareFlowControl)
        XCTAssertFalse(SerialOptions.standardRates.contains(921600), "921600 baud has to go through IOSSIOSPEED")
    }

    func testOpenOptionsRejectWhatTheSpecRejects() {
        typeError(try SerialOptions(nil), "no dictionary")
        typeError(try SerialOptions([String: Any]()), "baudRate is required")
        for baud: Any in [0, -9600, 1.5, "9600", true, Double.nan, NSNull()] {
            typeError(try SerialOptions(["baudRate": baud]), "baudRate \(baud)")
        }
        typeError(try SerialOptions(["baudRate": 9600, "dataBits": 9]))
        typeError(try SerialOptions(["baudRate": 9600, "stopBits": 3]))
        typeError(try SerialOptions(["baudRate": 9600, "parity": "mark"]))
        typeError(try SerialOptions(["baudRate": 9600, "parity": 1]))
        typeError(try SerialOptions(["baudRate": 9600, "bufferSize": 0]))
        typeError(try SerialOptions(["baudRate": 9600, "bufferSize": SerialOptions.maxBufferSize + 1]))
        typeError(try SerialOptions(["baudRate": 9600, "flowControl": "software"]))
    }

    func testSignalsMoveOnlyTheLinesThePageNamed() throws {
        typeError(try SerialSignals([String: Any]()), "at least one member")
        typeError(try SerialSignals(["dataTerminalReady": "yes"]))
        let both = TIOCM_DTR | TIOCM_RTS | TIOCM_CTS
        XCTAssertEqual(try SerialSignals(["dataTerminalReady": false]).applied(to: both), TIOCM_RTS | TIOCM_CTS,
                       "Dropping DTR must leave RTS, and the lines that are not ours, alone")
        XCTAssertEqual(try SerialSignals(["requestToSend": false]).applied(to: both), TIOCM_DTR | TIOCM_CTS)
        // esptool's reset into the bootloader: DTR low with RTS high, in one step.
        XCTAssertEqual(try SerialSignals(["dataTerminalReady": false, "requestToSend": true]).applied(to: TIOCM_DTR), TIOCM_RTS)
        let breakOnly = try SerialSignals(["break": true])
        XCTAssertEqual(breakOnly.applied(to: both), both)
        XCTAssertEqual(breakOnly.breakSignal, true)
        XCTAssertEqual(SerialSignals.inputs(TIOCM_CTS | TIOCM_DSR),
                       ["dataCarrierDetect": false, "clearToSend": true, "ringIndicator": false, "dataSetReady": true])
    }

    func testFiltersMatchByVendorAndOptionalProduct() throws {
        let cp2102 = SerialDevice(path: "/dev/cu.usbserial-0001", vendorID: 0x10c4, productID: 0xea60)
        let ch340 = SerialDevice(path: "/dev/cu.wchusbserial10", vendorID: 0x1a86, productID: 0x7523)
        let builtIn = SerialDevice(path: "/dev/cu.Bluetooth-Incoming-Port")
        let all = [cp2102, ch340, builtIn]
        XCTAssertEqual(WebSerial.Filter.candidates(all, filters: try WebSerial.Filter.parse(nil)), all)
        XCTAssertEqual(WebSerial.Filter.candidates(all, filters: try WebSerial.Filter.parse([[String: Any]]())), all)
        XCTAssertEqual(WebSerial.Filter.candidates(all, filters: try WebSerial.Filter.parse([["usbVendorId": 0x10c4]])), [cp2102])
        XCTAssertEqual(WebSerial.Filter.candidates(all, filters: try WebSerial.Filter.parse(
            [["usbVendorId": 0x10c4, "usbProductId": 1], ["usbVendorId": 0x1a86, "usbProductId": 0x7523]])), [ch340])
        XCTAssertEqual(WebSerial.Filter.candidates(all, filters: try WebSerial.Filter.parse([["bluetoothServiceClassId": "1101"]])), [],
                       "A Bluetooth-only filter is valid and matches no port here")
        typeError(try WebSerial.Filter.parse([["usbProductId": 0xea60]]), "a product needs its vendor")
        typeError(try WebSerial.Filter.parse([[String: Any]()]), "an empty filter filters nothing")
        typeError(try WebSerial.Filter.parse([["usbVendorId": 0x10000]]))
        typeError(try WebSerial.Filter.parse([["usbVendorId": "4292"]]))
        typeError(try WebSerial.Filter.parse([["usbVendorId": 1, "bluetoothServiceClassId": "1101"]]))
        typeError(try WebSerial.Filter.parse("all"))
    }

    func testAGrantFollowsItsDeviceAndNoOther() {
        let numbered = WebSerial.Grant(id: "a", path: "/dev/cu.usbserial-A1", vendorID: 0x0403, productID: 0x6001,
                                       serialNumber: "A1", name: "FT232")
        XCTAssertTrue(numbered.matches(SerialDevice(path: "/dev/cu.usbserial-moved", vendorID: 0x0403, productID: 0x6001, serialNumber: "A1")),
                      "A device with a serial number is itself in any socket")
        XCTAssertFalse(numbered.matches(SerialDevice(path: "/dev/cu.usbserial-A1", vendorID: 0x0403, productID: 0x6001, serialNumber: "B2")))
        let plain = WebSerial.Grant(id: "b", path: "/dev/cu.usbserial-1420", vendorID: 0x1a86, productID: 0x7523, name: "CH340")
        XCTAssertTrue(plain.matches(SerialDevice(path: "/dev/cu.usbserial-1420", vendorID: 0x1a86, productID: 0x7523)))
        XCTAssertFalse(plain.matches(SerialDevice(path: "/dev/cu.usbserial-1430", vendorID: 0x1a86, productID: 0x7523)),
                       "Without a serial number, another socket could be another board")
        XCTAssertFalse(plain.matches(SerialDevice(path: "/dev/cu.usbserial-1420", vendorID: 0x10c4, productID: 0xea60)),
                       "A different adapter in the same socket takes the same path and must not take the grant")
    }

    func testOnlySecureOriginsMayAsk() throws {
        func scope(_ url: String) throws -> WebSerial.Scope { try XCTUnwrap(WebSerial.Scope(url: URL(string: url), profileID: profile)) }
        for url in ["https://flasher.example", "http://localhost:8080", "http://127.0.0.1:3000",
                    "http://127.8.8.8", "http://[::1]:8000"] {
            XCTAssertTrue(WebSerial.isSecure(try scope(url)), url)
        }
        // 0.0.0.0 reaches this Mac too, but it is no loopback address and no secure context.
        for url in ["http://flasher.example", "http://127.evil.example", "http://localhost.evil.example", "http://app.localhost", "http://192.168.1.4",
                    "http://0.0.0.0:8080"] {
            XCTAssertFalse(WebSerial.isSecure(try scope(url)), url)
        }
        XCTAssertNil(WebSerial.Scope(url: URL(string: "file:///tmp/flasher.html"), profileID: profile), "No origin, no grant")
    }

    func testGrantsStayWithTheirOriginProfileAndPrivateTab() throws {
        let origin = URL(string: "https://flasher.example")
        let scope = try XCTUnwrap(WebSerial.Scope(url: origin, profileID: profile))
        let device = SerialDevice(path: "/dev/cu.usbserial-0001", vendorID: 0x10c4, productID: 0xea60,
                                  product: "CP2102", serialNumber: "0001")
        let grant = WebSerial.grant(device, scope: scope)
        XCTAssertEqual(WebSerial.grants(scope: scope), [grant])
        XCTAssertEqual(grant.name, "CP2102 (cu.usbserial-0001)")
        XCTAssertEqual(WebSerial.grant(device, scope: scope).id, grant.id, "Picking a device again must not add a second grant")
        XCTAssertEqual(WebSerial.grants(scope: scope).count, 1)
        for url in ["http://flasher.example", "https://flasher.example:8443", "https://sub.flasher.example"] {
            XCTAssertTrue(WebSerial.grants(scope: WebSerial.Scope(url: URL(string: url), profileID: profile)).isEmpty, url)
        }
        let otherProfile = UUID()
        defer { WebSerial.forgetAll(profileID: otherProfile) }
        let elsewhere = try XCTUnwrap(WebSerial.Scope(url: origin, profileID: otherProfile))
        XCTAssertTrue(WebSerial.grants(scope: elsewhere).isEmpty)
        XCTAssertTrue(WebSerial.grants(scope: nil).isEmpty)

        let privateTab = UUID()
        let privateScope = try XCTUnwrap(WebSerial.Scope(url: origin, profileID: profile, privateTabID: privateTab))
        XCTAssertTrue(WebSerial.grants(scope: privateScope).isEmpty, "A private tab must not inherit the profile's grants")
        WebSerial.forget(scope: scope, id: grant.id)
        WebSerial.grant(device, scope: privateScope)
        XCTAssertEqual(WebSerial.grants(scope: privateScope).count, 1)
        XCTAssertTrue(WebSerial.grants(scope: WebSerial.Scope(url: origin, profileID: profile, privateTabID: UUID())).isEmpty)
        XCTAssertTrue(WebSerial.grants(scope: scope).isEmpty)
        XCTAssertFalse(UserDefaults.vane.dictionaryRepresentation().keys.contains { $0.hasPrefix("serialPort.v1." + profile.uuidString.lowercased()) },
                       "A private grant is never written down")
        WebSerial.forgetPrivate(tabID: privateTab)
        XCTAssertTrue(WebSerial.grants(scope: privateScope).isEmpty)

        WebSerial.grant(device, scope: elsewhere)
        let again = WebSerial.grant(device, scope: scope)
        WebSerial.forget(scope: scope, id: again.id)
        XCTAssertTrue(WebSerial.grants(scope: scope).isEmpty)
        XCTAssertEqual(WebSerial.grants(scope: elsewhere).count, 1, "Forgetting one origin's port leaves the others")
        WebSerial.grant(device, scope: scope)
        WebSerial.forgetAll(profileID: profile)
        XCTAssertTrue(WebSerial.grants(scope: scope).isEmpty)
        XCTAssertEqual(WebSerial.grants(scope: elsewhere).count, 1, "Removing a profile's grants leaves other profiles alone")
    }

    func testSiteControlsListEachGrantedPortAsARowThatForgetsIt() {
        var model = SiteControlModel(host: "flasher.example", scheme: "https")
        XCTAssertFalse(model.rows.contains { $0.id == .serial(0) })
        model.serialPorts = ["CP2102 (cu.usbserial-0001)"]
        let row = model.rows.first { $0.id == .serial(0) }
        XCTAssertEqual(row?.title, "Serial Port: CP2102 (cu.usbserial-0001)")
        XCTAssertEqual(row?.control, .toggle(true))
        XCTAssertEqual(model.settings.first { $0.id == .serial(0) }?.value, "Allowed")
    }
}

/// The read, write and signal paths of one open port, against a pty.
final class SerialConnectionTests: XCTestCase {
    /// The ports this test opened. A read waits for bytes and a write for room with no limit
    /// of their own, so a test whose device stopped short would wait for good and take the
    /// whole run with it. One that has not finished in a minute has its ports closed, which
    /// ends every read and write on them, and it fails where it stands.
    private let watch = OSAllocatedUnfairLock(initialState: Watch())
    private struct Watch: Sendable { var ports: [SerialConnection] = [], over = false, expired = false }

    override func setUp() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [watch] in
            watch.withLock { state -> [SerialConnection] in
                guard !state.over else { return [] }
                state.expired = true
                return state.ports
            }.forEach { $0.close() }
        }
    }

    override func tearDown() {
        let state = watch.withLock { state -> Watch in state.over = true; return state }
        state.ports.forEach { $0.close() }
        XCTAssertFalse(state.expired, "The test had not finished in 60 seconds; its ports were closed to end it")
    }

    /// The native buffer is the page's `bufferSize` and no more, unless a test says otherwise:
    /// a megabyte of slack would hide what these fixtures are about.
    private func open(_ pty: SerialPty, bufferSize: Int = 255, readBuffer: Int = 0) async throws(SerialError) -> SerialConnection {
        var options = SerialOptions(baudRate: 115200)
        options.bufferSize = bufferSize
        let port = try await SerialConnection.open(path: pty.path, options: options, readBuffer: readBuffer)
        if watch.withLock({ $0.ports.append(port); return $0.expired }) { port.close() }
        return port
    }

    private func read(_ port: SerialConnection, _ count: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < count {
            let chunk = try await port.read()
            XCTAssertFalse(chunk.isEmpty, "An empty read means cancelled or closed")
            if chunk.isEmpty { break }
            out += chunk
        }
        return out
    }

    func testBytesCrossBothWaysUnchanged() async throws {
        let pty = try SerialPty()
        let port = try await open(pty)
        defer { port.close() }
        // Every byte value: a raw port must not eat ^C, ^S, NUL or 0xFF, or turn CR into LF.
        let bytes = (0...255).map { UInt8($0) }
        try await port.write(Data(bytes))
        let heard = try await pty.receive(bytes.count)
        XCTAssertEqual(heard, bytes)
        try await pty.send(bytes.reversed())
        let got = try await read(port, bytes.count)
        XCTAssertEqual(got, bytes.reversed())
    }

    func testAReadWaitsForDataAndCancelEndsItEmptyHanded() async throws {
        let pty = try SerialPty()
        let port = try await open(pty)
        defer { port.close() }
        async let waiting = port.read()
        try await Task.sleep(for: .milliseconds(50))
        try await pty.send([7, 8, 9])
        let first = try await waiting
        XCTAssertEqual([UInt8](first), [7, 8, 9])

        async let cancelled = port.read()
        try await Task.sleep(for: .milliseconds(50))
        port.cancelRead()
        let empty = try await cancelled
        XCTAssertTrue(empty.isEmpty)
        try await pty.send([1])
        let after = try await read(port, 1)
        XCTAssertEqual(after, [1], "A cancelled read must not take the port down with it")
    }

    /// A page asks for 255 bytes unless it says otherwise, which a UART at 921600 baud sends
    /// in 3 ms. What is held natively must not be that small, or a busy page loses bytes.
    func testThePortKeepsTakingBytesWhileNobodyReads() async throws {
        let pty = try SerialPty()
        let port = try await open(pty, bufferSize: 16, readBuffer: SerialOptions.minReadBuffer)
        defer { port.close() }
        let burst = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        // The tty itself holds about a kilobyte, so this ends only if the port took the rest.
        try await pty.send(burst)
        let got = try await read(port, burst.count)
        XCTAssertEqual(got, burst)
    }

    func testASmallBufferHoldsTheDeviceBackWithoutLosingBytes() async throws {
        let pty = try SerialPty()
        let port = try await open(pty, bufferSize: 16)
        defer { port.close() }
        let megabyte = (0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let started = ContinuousClock.now
        async let sending: Void = pty.send(megabyte)
        let got = try await read(port, megabyte.count)
        try await sending
        XCTAssertEqual(got, megabyte)
        let inbound = Double(megabyte.count) / (ContinuousClock.now - started).seconds

        // The other way, through a full tty queue: `write` has to wait for room, not fail.
        let outboundStart = ContinuousClock.now
        async let heard = pty.receive(megabyte.count)
        try await port.write(Data(megabyte))
        let received = try await heard
        XCTAssertEqual(received, megabyte)
        let outbound = Double(megabyte.count) / (ContinuousClock.now - outboundStart).seconds
        // 921600 baud is 92,160 bytes a second. Reported, not asserted: CI has no wall-clock limits.
        print(String(format: "Serial pty throughput: in %.0f KB/s, out %.0f KB/s (921600 baud needs 90 KB/s)",
                     inbound / 1024, outbound / 1024))
    }

    func testAPtyHasNoModemLinesAndSaysSoInsteadOfHanging() async throws {
        let pty = try SerialPty()
        let port = try await open(pty)
        defer { port.close() }
        for signals in [SerialSignals(dataTerminalReady: false), SerialSignals(requestToSend: true)] {
            do {
                try await port.setSignals(signals)
                XCTFail("A pty cannot set modem lines")
            } catch { XCTAssertEqual(error.name, "NetworkError") }
        }
        do {
            _ = try await port.signals()
            XCTFail("A pty cannot read modem lines")
        } catch { XCTAssertEqual(error.name, "NetworkError") }
        // Break takes the other ioctl; whether a pty accepts it is the kernel's business.
        try? await port.setSignals(SerialSignals(breakSignal: true))
        try await port.write(Data([1]))
        let heard = try await pty.receive(1)
        XCTAssertEqual(heard, [1], "A refused signal must leave the port usable")
    }

    /// `await port.close(); await port.open()` is how a flasher changes baud rate. On a real
    /// node the first descriptor still holds the exclusive lock until it is closed, so
    /// `close` may not return before that, even with a write the device is not taking.
    func testCloseReturnsOnlyOnceTheDescriptorIsGivenBack() async throws {
        let pty = try SerialPty()
        XCTAssertTrue(pty.slaveIsClosed)
        let port = try await open(pty)
        XCTAssertFalse(pty.slaveIsClosed)
        async let stuck = serialFailure { try await port.write(Data(repeating: 7, count: 1 << 20)) }
        defer { port.close() }    // before `stuck` is waited for, whatever throws below
        // The write has begun, and nothing reads the rest: it waits in the tty queue.
        _ = try await pty.receive(1)
        await port.closeAndWait()
        XCTAssertTrue(pty.slaveIsClosed, "close() returned with the descriptor still open")
        let abandoned = await stuck
        XCTAssertEqual(abandoned, "NetworkError")
        await port.closeAndWait()    // twice is once, and the second caller is answered too

        let next = try await open(pty)
        try await pty.send([5])
        let got = try await read(next, 1)
        XCTAssertEqual(got, [5], "The next owner gets the device at once")
        await next.closeAndWait()
        XCTAssertTrue(pty.slaveIsClosed)
    }

    func testAStalledDeviceCannotQueueWritesWithoutLimit() async throws {
        let pty = try SerialPty()
        let port = try await open(pty)
        async let stuck = serialFailure { try await port.write(Data(count: SerialOptions.maxBufferSize)) }
        defer { port.close() }    // before `stuck` is waited for, whatever throws below
        // The whole allowance is in one write that has begun, and nothing reads the rest.
        _ = try await pty.receive(1)
        // Were the extra byte accepted it would wait behind the rest for good; fail instead.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { port.close() }
        let over = await serialFailure { try await port.write(Data([1])) }
        XCTAssertEqual(over, "QuotaExceededError")
        await port.closeAndWait()
        let abandoned = await stuck
        XCTAssertEqual(abandoned, "NetworkError")
    }

    /// The exclusive lock itself (`TIOCEXCL`) is not covered: the kernel enforces it on
    /// serial nodes ("Resource busy", measured on a built-in port) but not on ptys.
    func testCloseEndsTheWaitingReadAndAVanishedDeviceIsALostOne() async throws {
        let pty = try SerialPty()
        let port = try await open(pty)
        async let waiting = port.read()
        try await Task.sleep(for: .milliseconds(50))
        port.close()
        let closed = try await waiting
        XCTAssertTrue(closed.isEmpty, "Closing ends the waiting read without an error")
        port.close()    // twice is once
        do {
            try await port.write(Data([1]))
            XCTFail("A closed port takes no more bytes")
        } catch { XCTAssertEqual(error.name, "NetworkError") }

        let second = try await open(pty)
        defer { second.close() }
        try await pty.send([5])
        let got = try await read(second, 1)
        XCTAssertEqual(got, [5], "The next owner gets the device")

        let gone = try SerialPty()
        let orphan = try await open(gone)
        defer { orphan.close() }
        try await gone.send([4, 2])
        try await Task.sleep(for: .milliseconds(50))
        hangUp(gone)
        let last = try await read(orphan, 2)
        XCTAssertEqual(last, [4, 2], "What arrived before the device left is still delivered")
        do {
            let data = try await orphan.read()
            XCTFail("A device that left must fail the read, got \(data.count) bytes")
        } catch { XCTAssertEqual(error, .lost) }
    }

    func testUnopenablePathsFailCleanly() async {
        do {
            _ = try await SerialConnection.open(path: "/dev/cu.vane-no-such-port", options: SerialOptions(baudRate: 9600))
            XCTFail("There is no such port")
        } catch { XCTAssertEqual(error.name, "NetworkError") }
    }

    /// What pulling the cable does: the node is revoked under the open descriptor. Closing
    /// the master would not do it, because a port opened CLOCAL ignores the carrier drop.
    private func hangUp(_ pty: SerialPty) { XCTAssertEqual(revoke(pty.path), 0) }
}

/// The DOMException name a call failed with, or nil if it did not fail.
private func serialFailure(_ work: () async throws -> Void) async -> String? {
    do { try await work(); return nil } catch { return (error as? SerialError)?.name ?? "\(error)" }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
