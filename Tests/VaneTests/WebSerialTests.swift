import Darwin
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
        // The port takes the tty exclusively, and that lasts until its last close: a slave
        // descriptor kept here would leave it locked after the port had gone.
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.master = master
        path = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    deinit { Darwin.close(master) }

    var device: SerialDevice {
        SerialDevice(path: path, vendorID: 0x10c4, productID: 0xea60, product: "Fixture UART", serialNumber: "F1")
    }

    /// The device speaks.
    func send(_ bytes: [UInt8]) async throws {
        var offset = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, $0.count - offset) }
            if sent > 0 { offset += sent; continue }
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// What the device heard. Never blocks the caller's thread, so a page can keep talking.
    func receive(_ count: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = ContinuousClock.now + .seconds(10)
        while out.count < count {
            let got = Darwin.read(master, &chunk, min(chunk.count, count - out.count))
            if got > 0 { out += chunk[0..<got]; continue }
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(2))
        }
        return out
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
        for url in ["https://flasher.example", "http://localhost:8080", "http://app.localhost", "http://127.0.0.1:3000",
                    "http://127.8.8.8", "http://[::1]:8000"] {
            XCTAssertTrue(WebSerial.isSecure(try scope(url)), url)
        }
        for url in ["http://flasher.example", "http://127.evil.example", "http://localhost.evil.example", "http://192.168.1.4"] {
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
    private func open(_ pty: SerialPty, bufferSize: Int = 255) async throws(SerialError) -> SerialConnection {
        var options = SerialOptions(baudRate: 115200)
        options.bufferSize = bufferSize
        return try await SerialConnection.open(path: pty.path, options: options)
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

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
