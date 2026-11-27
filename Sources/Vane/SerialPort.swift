import Foundation
import IOKit
import IOKit.serial
import Synchronization

/// The native half of Web Serial: which serial devices this Mac has, and one open port.
/// Nothing here knows about pages, origins or grants; see WebSerial.swift for those.

/// What a page is told when something fails: a DOMException name (or `TypeError`) and text.
struct SerialError: Error, Equatable, Sendable {
    let name: String
    let message: String

    static func type(_ message: String) -> SerialError { SerialError(name: "TypeError", message: message) }
    static func network(_ message: String) -> SerialError { SerialError(name: "NetworkError", message: message) }
    static func state(_ message: String) -> SerialError { SerialError(name: "InvalidStateError", message: message) }
    static func security(_ message: String) -> SerialError { SerialError(name: "SecurityError", message: message) }
    static let lost = network("The device has been lost.")
    /// Not one of the spec's write errors: its sink never holds more than it was asked to.
    static let writeQueueFull = SerialError(name: "QuotaExceededError", message: "Too much data is waiting to be written.")
}

/// One `/dev/cu.*` node, with its USB identity when it has one.
struct SerialDevice: Hashable, Sendable {
    let path: String
    var vendorID: Int?
    var productID: Int?
    var product: String?
    var serialNumber: String?

    /// "CP2102 USB to UART Bridge (cu.usbserial-0001)", or just the node for a port with no name.
    var label: String {
        let node = (path as NSString).lastPathComponent
        guard let product, !product.isEmpty else { return node }
        return "\(product) (\(node))"
    }
}

/// `SerialPort.open()`'s options, as the spec validates them.
struct SerialOptions: Equatable, Sendable {
    enum Parity: String, Sendable { case none, even, odd }
    var baudRate: Int
    var dataBits = 8
    var stopBits = 1
    var parity = Parity.none
    var bufferSize = 255
    var hardwareFlowControl = false

    /// Chromium's ceiling for one port's buffer.
    static let maxBufferSize = 16 * 1024 * 1024
    /// What is held natively before the device is made to wait, whatever smaller size the
    /// page asked for. The page's `bufferSize` (255 by default) is far less than a UART at
    /// 921600 baud sends while the main thread is busy for a moment, and a driver with no
    /// flow control drops what it cannot hand over.
    static let minReadBuffer = 1 << 20

    /// The rates termios takes directly; anything else goes through `IOSSIOSPEED`.
    static let standardRates: Set<Int> = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600,
                                          14400, 19200, 28800, 38400, 57600, 76800, 115200, 230400]

    init(baudRate: Int) { self.baudRate = baudRate }

    /// A page's dictionary. Anything missing takes the spec's default; anything wrong is a
    /// TypeError, never a guess.
    init(_ body: Any?) throws(SerialError) {
        guard let body = body as? [String: Any] else { throw .type("Missing serial options.") }
        func integer(_ key: String) throws(SerialError) -> Int? {
            guard let value = body[key], !(value is NSNull) else { return nil }
            // A JavaScript `true` is an NSNumber too; it is not a number of bits.
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let exact = Int(exactly: number.doubleValue) else { throw .type("\(key) must be a whole number.") }
            return exact
        }
        func string(_ key: String) throws(SerialError) -> String? {
            guard let value = body[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw .type("\(key) is not valid.") }
            return text
        }
        guard let baud = try integer("baudRate"), (1...Int(UInt32.max)).contains(baud) else {
            throw .type("Requested baud rate must be greater than zero.")
        }
        baudRate = baud
        if let bits = try integer("dataBits") {
            guard bits == 7 || bits == 8 else { throw .type("Requested number of data bits must be 7 or 8.") }
            dataBits = bits
        }
        if let bits = try integer("stopBits") {
            guard bits == 1 || bits == 2 else { throw .type("Requested number of stop bits must be 1 or 2.") }
            stopBits = bits
        }
        if let name = try string("parity") {
            guard let value = Parity(rawValue: name) else { throw .type("Requested parity must be none, even or odd.") }
            parity = value
        }
        if let size = try integer("bufferSize") {
            guard size > 0 else { throw .type("Requested buffer size must be greater than zero.") }
            guard size <= Self.maxBufferSize else { throw .type("Requested buffer size is too large.") }
            bufferSize = size
        }
        if let flow = try string("flowControl") {
            guard flow == "none" || flow == "hardware" else { throw .type("Requested flow control must be none or hardware.") }
            hardwareFlowControl = flow == "hardware"
        }
    }
}

/// `setSignals()`: each line is left alone unless the page named it.
struct SerialSignals: Equatable, Sendable {
    var dataTerminalReady: Bool?
    var requestToSend: Bool?
    var breakSignal: Bool?

    init(dataTerminalReady: Bool? = nil, requestToSend: Bool? = nil, breakSignal: Bool? = nil) {
        self.dataTerminalReady = dataTerminalReady; self.requestToSend = requestToSend; self.breakSignal = breakSignal
    }

    init(_ body: Any?) throws(SerialError) {
        let body = body as? [String: Any] ?? [:]
        func flag(_ key: String) throws(SerialError) -> Bool? {
            guard let value = body[key], !(value is NSNull) else { return nil }
            guard let flag = value as? Bool else { throw .type("\(key) must be true or false.") }
            return flag
        }
        dataTerminalReady = try flag("dataTerminalReady")
        requestToSend = try flag("requestToSend")
        breakSignal = try flag("break")
        guard dataTerminalReady != nil || requestToSend != nil || breakSignal != nil else {
            throw .type("Signals dictionary must contain at least one member.")
        }
    }

    /// The modem status word with DTR and RTS as asked, every other line as it was.
    func applied(to status: Int32) -> Int32 {
        var status = status
        if let dataTerminalReady { status = dataTerminalReady ? status | TIOCM_DTR : status & ~TIOCM_DTR }
        if let requestToSend { status = requestToSend ? status | TIOCM_RTS : status & ~TIOCM_RTS }
        return status
    }

    /// `getSignals()`'s answer for one modem status word.
    static func inputs(_ status: Int32) -> [String: Bool] {
        ["dataCarrierDetect": status & TIOCM_CAR != 0, "clearToSend": status & TIOCM_CTS != 0,
         "ringIndicator": status & TIOCM_RNG != 0, "dataSetReady": status & TIOCM_DSR != 0]
    }
}

/// The serial devices attached now, kept current by IOKit once anything asks.
@MainActor final class SerialDevices: ObservableObject {
    static let shared = SerialDevices()
    @Published private(set) var devices: [SerialDevice] = []
    /// Called after `devices` changes: a device was plugged in or pulled.
    var onChange: (() -> Void)?
    #if DEBUG
    /// Fixtures stand a pty in for hardware.
    var listForTesting: (() -> [SerialDevice])?
    #endif
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let changed: IOServiceMatchingCallback = { _, iterator in
            SerialDevices.drain(iterator)
            MainActor.assumeIsolated { SerialDevices.shared.refresh() }
        }
        // The iterators are kept for the life of the app: releasing one ends its notification.
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching(kIOSerialBSDServiceValue),
                                                changed, nil, &iterator) == KERN_SUCCESS {
                Self.drain(iterator)    // arms it
            }
        }
        refresh()
    }

    func refresh() {
        #if DEBUG
        let found = listForTesting?() ?? Self.list()
        #else
        let found = Self.list()
        #endif
        guard found != devices else { return }
        devices = found
        onChange?()
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    /// Every callout node IOKit lists, sorted by path. Reads the registry only; opens nothing.
    nonisolated static func list() -> [SerialDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  path.hasPrefix("/dev/cu.") else { continue }
            // The USB device is an ancestor of the serial client; a built-in port has none.
            func usb(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            found.append(SerialDevice(path: path, vendorID: usb("idVendor") as? Int, productID: usb("idProduct") as? Int,
                                      product: usb("USB Product Name") as? String,
                                      serialNumber: usb("USB Serial Number") as? String))
        }
        return found.sorted { $0.path < $1.path }
    }
}

/// One open port. Reads arrive on a dispatch source and wait in a buffer the page drains;
/// writes run on a queue of their own, so a stalled write cannot hold up a read.
final class SerialConnection: @unchecked Sendable {
    // <sys/ttycom.h> and <IOKit/serial/ioss.h> spell these as macros Swift cannot import.
    private static let TIOCEXCL: UInt = 0x2000_740d, TIOCSBRK: UInt = 0x2000_747b, TIOCCBRK: UInt = 0x2000_747a
    private static let TIOCMGET: UInt = 0x4004_746a, TIOCMSET: UInt = 0x8004_746d, TIOCOUTQ: UInt = 0x4004_7473
    private static let IOSSIOSPEED: UInt = 0x8008_5402

    private let fd: Int32
    private let limit: Int
    private let queue = DispatchQueue(label: "vane.serial.read")
    private let writes = DispatchQueue(label: "vane.serial.write")
    private let source: DispatchSourceRead
    private let closing = Atomic<Bool>(false)
    /// Bytes handed to `write` and not yet sent or given up on.
    private let queuedWrites = Atomic<Int>(0)
    // Everything below belongs to `queue`.
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var waiter: ((Result<Data, SerialError>) -> Void)?
    private var paused = false
    private var lost = false
    private var sourceDone = false
    private var closed = false
    private var released = false
    private var onRelease: [@Sendable () -> Void] = []

    /// Off the main thread: opening a Bluetooth port waits for its radio link. `readBuffer`
    /// is a fixture's way to a small native buffer; a page never gets less than the default.
    static func open(path: String, options: SerialOptions,
                     readBuffer: Int = SerialOptions.minReadBuffer) async throws(SerialError) -> SerialConnection {
        let result: Result<SerialConnection, SerialError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(SerialError) { continuation.resume(returning: .success(try SerialConnection(path: path, options: options, readBuffer: readBuffer))) }
                catch { continuation.resume(returning: .failure(error)) }
            }
        }
        return try result.get()
    }

    private init(path: String, options: SerialOptions, readBuffer: Int) throws(SerialError) {
        // Nonblocking, so opening never waits for carrier and a write can be abandoned.
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .network("Failed to open serial port: \(String(cString: strerror(errno))).") }
        do throws(SerialError) {
            // One owner at a time: a second tab, or another app, gets "busy" rather than half the bytes.
            guard ioctl(fd, Self.TIOCEXCL) == 0 else { throw Self.failure("lock") }
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else { throw Self.failure("configure") }
            cfmakeraw(&settings)
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
            settings.c_cflag &= ~tcflag_t(CSIZE | CSTOPB | PARENB | PARODD | CRTSCTS)
            settings.c_cflag |= tcflag_t(options.dataBits == 7 ? CS7 : CS8)
            if options.stopBits == 2 { settings.c_cflag |= tcflag_t(CSTOPB) }
            if options.parity != .none { settings.c_cflag |= tcflag_t(PARENB) }
            if options.parity == .odd { settings.c_cflag |= tcflag_t(PARODD) }
            if options.hardwareFlowControl { settings.c_cflag |= tcflag_t(CRTSCTS) }
            // A read with nothing waiting says EAGAIN, so zero bytes can only mean the device left.
            withUnsafeMutableBytes(of: &settings.c_cc) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
            let standard = SerialOptions.standardRates.contains(options.baudRate)
            cfsetspeed(&settings, speed_t(standard ? options.baudRate : 9600))
            guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw Self.failure("configure") }
            if !standard {
                // After tcsetattr, which would otherwise put the placeholder rate back.
                var speed = speed_t(options.baudRate)
                guard ioctl(fd, Self.IOSSIOSPEED, &speed) == 0 else { throw Self.failure("set the baud rate of") }
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
        limit = max(options.bufferSize, readBuffer)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in receive() }
        source.setCancelHandler { [self] in
            sourceDone = true
            if closed { releaseDescriptor() }
        }
        source.resume()
    }

    private static func failure(_ what: String) -> SerialError {
        .network("Failed to \(what) serial port: \(String(cString: strerror(errno))).")
    }

    private func receive() {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            buffer.append(chunk, count: count)
            deliver()
            // The page is far behind: stop reading and let the driver hold what follows.
            // ponytail: no BufferOverrunError; past `limit` the kernel's own queue is the overflow.
            if buffer.count >= limit, !paused { paused = true; source.suspend() }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            lost = true
            source.cancel()
            deliver()
        }
    }

    private func deliver() {
        guard let waiter else { return }
        if !buffer.isEmpty {
            self.waiter = nil
            waiter(.success(buffer))
            buffer = Data()
            if paused { paused = false; source.resume() }
        } else if closed || lost {
            self.waiter = nil
            waiter(lost ? .failure(.lost) : .success(Data()))
        }
    }

    /// The next bytes, however many have arrived. Empty means the read was cancelled or the
    /// port closed. One read at a time; a second one ends the first empty-handed.
    func read() async throws(SerialError) -> Data {
        let result: Result<Data, SerialError> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                waiter?(.success(Data()))
                waiter = { continuation.resume(returning: $0) }
                deliver()
            }
        }
        return try result.get()
    }

    /// `readable.cancel()`: end the waiting read and drop what was received.
    func cancelRead() {
        queue.async { [self] in
            buffer = Data()
            tcflush(fd, TCIFLUSH)
            waiter?(.success(Data()))
            waiter = nil
            if paused { paused = false; source.resume() }
        }
    }

    /// Resolves once the kernel has taken every byte. A device that takes none cannot be
    /// made to hold an unbounded backlog: past `maxBufferSize` waiting, a write is refused.
    func write(_ data: Data) async throws(SerialError) {
        guard queuedWrites.add(data.count, ordering: .relaxed).newValue <= SerialOptions.maxBufferSize else {
            queuedWrites.subtract(data.count, ordering: .relaxed)
            throw .writeQueueFull
        }
        defer { queuedWrites.subtract(data.count, ordering: .relaxed) }
        let failure: SerialError? = await withCheckedContinuation { continuation in
            writes.async { [self] in continuation.resume(returning: send(data)) }
        }
        if let failure { throw failure }
    }

    private func send(_ data: Data) -> SerialError? {
        var offset = 0
        while offset < data.count {
            if closing.load(ordering: .relaxed) { return .network("The port is closed.") }
            let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if sent > 0 { offset += sent; continue }
            guard sent < 0, errno == EAGAIN || errno == EINTR else { return .lost }
            // Flow control, or a full queue. Wake regularly so `close()` is never stuck behind this.
            var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            poll(&wait, 1, 100)
        }
        return nil
    }

    /// `writable.close()`: wait until what was written has left. Polled rather than
    /// `tcdrain`, which could not be interrupted by `close()`.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writes.async { [self] in
                var queued: Int32 = 0
                while !closing.load(ordering: .relaxed), ioctl(fd, Self.TIOCOUTQ, &queued) == 0, queued > 0 { usleep(2000) }
                continuation.resume()
            }
        }
    }

    /// `writable.abort()`: drop what has not been sent.
    func discardOutput() { writes.async { [self] in if !closing.load(ordering: .relaxed) { tcflush(fd, TCOFLUSH) } } }

    /// Read-modify-write in one go, as Chromium does it, so setting DTR does not move RTS.
    func setSignals(_ signals: SerialSignals) async throws(SerialError) {
        let failure: SerialError? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed else { return continuation.resume(returning: .state("The port is closed.")) }
                if signals.dataTerminalReady != nil || signals.requestToSend != nil {
                    var status: Int32 = 0
                    guard ioctl(fd, Self.TIOCMGET, &status) == 0 else { return continuation.resume(returning: Self.failure("get control signals of")) }
                    status = signals.applied(to: status)
                    guard ioctl(fd, Self.TIOCMSET, &status) == 0 else { return continuation.resume(returning: Self.failure("set control signals of")) }
                }
                if let brk = signals.breakSignal, ioctl(fd, brk ? Self.TIOCSBRK : Self.TIOCCBRK) != 0 {
                    return continuation.resume(returning: Self.failure("set the break signal of"))
                }
                continuation.resume(returning: nil)
            }
        }
        if let failure { throw failure }
    }

    func signals() async throws(SerialError) -> [String: Bool] {
        let result: Result<[String: Bool], SerialError> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                var status: Int32 = 0
                guard !closed, ioctl(fd, Self.TIOCMGET, &status) == 0 else {
                    return continuation.resume(returning: .failure(closed ? .state("The port is closed.") : Self.failure("get control signals of")))
                }
                continuation.resume(returning: .success(SerialSignals.inputs(status)))
            }
        }
        return try result.get()
    }

    /// Ends the waiting read, abandons any write, and gives the descriptor back once both
    /// queues have let go of it. Safe to call twice. `lost` is the device or its grant going
    /// away rather than the page closing it: the waiting read then fails instead of ending.
    /// `then` runs once the descriptor is closed, which is when the device can be opened again.
    func close(lost gone: Bool = false, then done: (@Sendable () -> Void)? = nil) {
        closing.store(true, ordering: .relaxed)
        queue.async { [self] in
            if let done { if released { done() } else { onRelease.append(done) } }
            guard !closed else { return }
            closed = true
            if gone { lost = true }
            buffer = Data()
            deliver()
            if sourceDone { releaseDescriptor() } else {
                if paused { paused = false; source.resume() }
                source.cancel()
            }
        }
    }

    /// `port.close()`: returns only once the exclusive lock is gone, so the page's next
    /// `open()` (a flasher changing baud rate closes and reopens at once) finds the port free.
    func closeAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in close { continuation.resume() } }
    }

    /// Behind whatever write is still running: closing under it could hand its descriptor
    /// number to another file.
    private func releaseDescriptor() {
        writes.async { [self] in
            Darwin.close(fd)
            queue.async { [self] in
                released = true
                onRelease.forEach { $0() }
                onRelease = []
            }
        }
    }
}
