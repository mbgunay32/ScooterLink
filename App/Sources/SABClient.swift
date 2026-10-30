import CoreBluetooth
import Foundation
import UIKit

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let isError: Bool
}

struct ScannedScooter: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var isHonda: Bool
    var id: UUID { peripheral.identifier }
}

struct ButtonPress: Identifiable {
    let id = UUID()
    let time = Date()
    let raw: UInt8
    var function: ButtonFunction? { ButtonFunction(rawValue: raw) }
}

/// Connects to the PCX dashboard, runs the RoadSync security handshake and button
/// assignments, then reports every handlebar press. Everything runs on the main queue.
final class SABClient: NSObject, ObservableObject {
    enum Phase: String {
        case idle = "Not connected"
        case scanning = "Scanning…"
        case connecting = "Connecting…"
        case securing = "Pairing (security)…"
        case assigning = "Setting up buttons…"
        case ready = "Ready: press handlebar buttons"
        case failed = "Stopped (see log)"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var devices: [ScannedScooter] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var presses: [ButtonPress] = []
    @Published private(set) var connectedName: String?
    @Published var showAllDevices = false
    @Published var registerColors = true
    @Published private(set) var theme = Theme.load()
    let screenColors = ScreenColors.theme
    @Published private(set) var dashScreen: LiveScreen?
    enum DashMode: String { case unknown = "?", phone = "Phone screen", scooter = "Scooter screen" }
    @Published private(set) var dashMode: DashMode = .unknown
    private var phoneScreenAttempts = 0
    private var lastPhoneScreenRequest: Date?
    private var readyAt: Date?
    private var setupTask: UIBackgroundTaskIdentifier = .invalid
    let ride = RideState()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0

    // Continuations for the async GATT helpers; each slot holds one outstanding request.
    private var readWaiters: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyStateWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notificationWaiters: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var notificationBuffer: [CBUUID: [Data]] = [:]
    private var discoveryWaiter: CheckedContinuation<Void, Error>?
    private var flow: Task<Void, Never>?
    private var requestId: UInt8 = 0
    private var lastSentScreen: LiveScreen?
    private var lastSentAt = Date.distantPast
    private var awaitingReceipt: (id: UInt8, since: Date)?
    private var receiptsLogged = 0
    private var autoPickFirstHonda = false
    private var lastAction: (function: ButtonFunction, at: Date)?
    private var userDisconnected = false

    private static let lastDeviceKey = "lastScooterIdentifier"

    struct GATTError: Error, CustomStringConvertible {
        let description: String
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                             CBCentralManagerOptionRestoreIdentifierKey: "scooterlink.central"])
    }

    // MARK: Public actions

    func startScan() {
        guard central.state == .poweredOn else { note("Bluetooth is not on yet (\(central.state.rawValue))", error: true); return }
        devices = []
        phase = .scanning
        // A scooter already linked at the OS level doesn't advertise; list it too.
        for p in central.retrieveConnectedPeripherals(withServices: SAB.customServices) {
            devices.append(ScannedScooter(peripheral: p, name: p.name ?? "Connected device", rssi: 0, isHonda: true))
            note("Already connected at system level: \(p.name ?? p.identifier.uuidString)")
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("Scanning. Turn the scooter on (ignition) and keep the phone close.")
    }

    func stopScan() {
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connect(_ device: ScannedScooter) {
        central.stopScan()
        userDisconnected = false
        autoPickFirstHonda = false
        peripheral = device.peripheral
        device.peripheral.delegate = self
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastDeviceKey)
        connectedName = device.name
        phase = .connecting
        note("Connecting to \(device.name)…")
        central.connect(device.peripheral)
    }

    /// Connects to the scooter as soon as it's around: picks up an iOS-level connection,
    /// otherwise leaves a pending connect (iOS completes it when the ignition comes on,
    /// even with the app in the background). Without a remembered scooter, scans for one.
    func autoConnect() {
        guard central.state == .poweredOn, peripheral?.state != .connected, peripheral?.state != .connecting else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: SAB.customServices).first {
            note("Scooter already linked by iOS, attaching")
            connect(ScannedScooter(peripheral: p, name: p.name ?? "Scooter", rssi: 0, isHonda: true))
        } else if let string = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
                  let uuid = UUID(uuidString: string),
                  let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            note("Waiting for the scooter (turn the ignition on)")
            connect(ScannedScooter(peripheral: p, name: p.name ?? "Scooter", rssi: 0, isHonda: true))
        } else {
            autoPickFirstHonda = true
            startScan()
        }
    }

    func reconnectLast() {
        guard let string = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let uuid = UUID(uuidString: string),
              let p = central.retrievePeripherals(withIdentifiers: [uuid]).first
        else { note("No remembered scooter yet. Scan first.", error: true); return }
        connect(ScannedScooter(peripheral: p, name: p.name ?? "Scooter", rssi: 0, isHonda: true))
    }

    func disconnect() {
        userDisconnected = true
        flow?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func forgetKey() {
        guard let peripheral else { note("Connect once first so the app knows which scooter.", error: true); return }
        KeyStore.delete(for: peripheral.identifier)
        note("Forgot the saved key for this scooter.")
    }

    func requestPhoneScreen() {
        guard let c = characteristics[SAB.DataCommunication.controlPoint] else { note("Not connected", error: true); return }
        requestId &+= 1
        let command = Data([SAB.DataCommunication.requestSABMode, requestId])
        Task { @MainActor in
            do {
                try await write(command, to: c)
                note("Sent REQUEST_SAB_MODE \(command.hex)")
            } catch { note("REQUEST_SAB_MODE failed: \(error)", error: true) }
        }
    }

    /// Asks the dash for the phone screen and retries until it reports the switch.
    /// Asks the dash for the phone screen. Retries are driven by Bluetooth events (the dash
    /// pings every 10 s), because timers don't run while the phone is locked.
    func ensurePhoneScreen() {
        guard phase == .ready, dashMode != .phone else { return }
        // Don't stack requests: at most one every 4 s.
        if let last = lastPhoneScreenRequest, Date().timeIntervalSince(last) < 4 { return }
        lastPhoneScreenRequest = Date()
        phoneScreenAttempts += 1
        requestPhoneScreen()
    }

    /// Called on every dash ping: keep asking during the first minute after connecting,
    /// then leave the screen to the rider (they may have switched to the scooter screen on purpose).
    private func retryPhoneScreenIfNeeded() {
        guard phase == .ready, dashMode != .phone, let readyAt, Date().timeIntervalSince(readyAt) < 60,
              phoneScreenAttempts < 6 else { return }
        note("Dash still on its own screen, asking again")
        ensurePhoneScreen()
    }

    func clearLog() {
        log = []
        presses = []
    }

    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return log.map { "\(formatter.string(from: $0.time)) \($0.isError ? "!! " : "")\($0.text)" }.joined(separator: "\n")
    }

    // MARK: Connection flow

    @MainActor
    private func runFlow(_ p: CBPeripheral) async {
        beginSetupTime()
        do {
            try await discoverEverything(p)
            await readVehicleInfo(p)
            phase = .securing
            try await secure(p)
            phase = .assigning
            try await assignButtons(p)
            try await subscribeData(p)
            phase = .ready
            readyAt = Date()
            phoneScreenAttempts = 0
            lastPhoneScreenRequest = nil
            note("✅ Ready. Press every handlebar button once and watch the list.")
            ensurePhoneScreen()
            endSetupTime()
        } catch is CancellationError {
            note("Flow cancelled")
            endSetupTime()
        } catch {
            phase = .failed
            note("Stopped: \(error)", error: true)
            endSetupTime()
        }
    }

    /// Extra background time so the ~10 s setup finishes with the phone locked.
    private func beginSetupTime() {
        endSetupTime()
        setupTask = UIApplication.shared.beginBackgroundTask(withName: "ScooterLink setup") { [weak self] in
            self?.endSetupTime()
        }
    }

    private func endSetupTime() {
        guard setupTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(setupTask)
        setupTask = .invalid
    }

    @MainActor
    private func discoverEverything(_ p: CBPeripheral) async throws {
        characteristics = [:]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            discoveryWaiter = c
            p.discoverServices(nil)
        }
        for service in p.services ?? [] {
            note("Service \(SAB.name(of: service.uuid))")
            for ch in service.characteristics ?? [] {
                characteristics[ch.uuid] = ch
                note("   • \(SAB.name(of: ch.uuid)) [\(ch.properties.short)]")
            }
        }
        let missing = [SAB.Security.controlPoint, SAB.Assignment.control, SAB.DataCommunication.functionSource]
            .filter { characteristics[$0] == nil }
        if !missing.isEmpty {
            throw GATTError(description: "this device is missing RoadSync characteristics: \(missing.map(SAB.name(of:)).joined(separator: ", "))")
        }
    }

    @MainActor
    private func readVehicleInfo(_ p: CBPeripheral) async {
        for (uuid, name) in SAB.VehicleInformation.characteristics {
            guard let c = characteristics[uuid], c.properties.contains(.read) else { continue }
            if let value = try? await read(c) {
                let text = String(data: value, encoding: .utf8).map { " \"\($0)\"" } ?? ""
                note("Vehicle \(name): \(value.hex)\(text)")
            }
        }
    }

    @MainActor
    private func secure(_ p: CBPeripheral) async throws {
        guard let status = characteristics[SAB.Security.status],
              let control = characteristics[SAB.Security.controlPoint],
              let source = characteristics[SAB.Security.dataSource]
        else { throw GATTError(description: "security service incomplete") }

        let statusValue = try await read(status)
        let alreadyKeyed = statusValue == Data([1])
        note("Security status: \(statusValue.hex)\(alreadyKeyed ? " (scooter already holds a key)" : " (no key yet)")")

        var key = KeyStore.load(for: p.identifier)
        if alreadyKeyed && key == nil {
            throw GATTError(description: """
                The scooter is already paired with another phone/app (RoadSync). \
                Delete the phone pairing in the PCX dashboard's Bluetooth/RoadSync menu, \
                turn the ignition off and on, then connect again.
                """)
        }
        if !alreadyKeyed {
            note("Key exchange: generating RSA-1024 key…")
            let rsa = try SABCrypto.makeRSAKey()
            let command = try SABCrypto.secureExchangeCommand(privateKey: rsa)
            try await write(command, to: control)
            let response = try await read(source)
            note("Exchange answer: \(response.count) bytes")
            let newKey = try SABCrypto.aesKey(fromExchangeResponse: response, privateKey: rsa)
            KeyStore.save(newKey, for: p.identifier)
            key = newKey
            note("🔑 Got and saved the scooter key")
        }
        guard let key else { throw GATTError(description: "no key") }

        try await write(try SABCrypto.validationCommand(key: key), to: control)
        let answer = try await read(source)
        do {
            let increment = try SABCrypto.checkValidationResponse(answer, key: key)
            note("🔓 Key validated (increment \(increment))")
        } catch {
            note("Validation answer: \(answer.hex)", error: true)
            throw error
        }
    }

    @MainActor
    private func assignButtons(_ p: CBPeripheral) async throws {
        guard let control = characteristics[SAB.Assignment.control] else { return }
        try await setNotify(control)
        let assignments = Assignments.all(includeColors: registerColors,
                                          theme: Features.customColours ? theme.palette : nil)
        var failures = 0
        for bytes in assignments {
            notificationBuffer[control.uuid] = []
            try await write(Data(bytes), to: control)
            let result = try await nextNotification(on: control, timeout: 3)
            if Assignments.isFailure(result) { failures += 1 }
            note("Assign \(Data(bytes).hex) → \(Assignments.describeResult(result))", error: Assignments.isFailure(result))
        }
        notificationBuffer[control.uuid] = []
        try await write(Data(SAB.Assignment.end), to: control)
        if let end = try? await nextNotification(on: control, timeout: 3) {
            note("Assignments end: \(end.hex)")
        } else {
            note("No end notification (continuing)")
        }
        if failures > 0 { note("\(failures) assignment(s) failed; buttons may still work", error: true) }
    }

    func applyTheme(_ newTheme: Theme) {
        theme = newTheme
        newTheme.save()
        note("🎨 Colour saved. The dash picks it up next time the ignition is turned on.")
    }

    // MARK: Dash screen

    @MainActor
    private func startScreenLoop() {
        pushScreen(force: true)
    }

    private func stopScreenLoop() {
        awaitingReceipt = nil
        lastSentScreen = nil
    }

    /// Sends the Ride screen when it changed (or every 10 s), one command in flight at a time.
    @MainActor
    func pushScreen(force: Bool = false) {
        guard let c = characteristics[SAB.DataCommunication.controlPoint], phase == .ready else { return }
        ride.refresh()
        let screen = ride.rideScreen(colors: screenColors)
        dashScreen = screen
        guard dashMode == .phone, Features.drawOnDash else { return }
        if let waiting = awaitingReceipt, Date().timeIntervalSince(waiting.since) < 2 { return }
        guard force || screen != lastSentScreen || Date().timeIntervalSince(lastSentAt) > 10 else { return }
        requestId &+= 1
        let id = requestId
        let bytes = screen.encode(requestId: id)
        awaitingReceipt = (id, Date())
        lastSentScreen = screen
        lastSentAt = Date()
        if receiptsLogged < 3 { note("⇢ Screen \(bytes.hex)") }
        Task { @MainActor in
            do { try await write(bytes, to: c) } catch { note("Screen send failed: \(error)", error: true) }
        }
    }

    private func handleReceipt(_ value: Data) {
        guard let receipt = Receipt(value) else { note("⇠ Data.ControlPoint: \(value.hex)"); return }
        if awaitingReceipt?.id == receipt.requestId { awaitingReceipt = nil }
        if !receipt.isOK {
            note("Dash refused command \(receipt.command) (status \(receipt.status), error at byte \(receipt.errorPosition.map(String.init) ?? "?"))", error: true)
        } else if receiptsLogged < 3 {
            receiptsLogged += 1
            note("Dash accepted command \(receipt.command) ✓")
        }
    }

    @MainActor
    private func subscribeData(_ p: CBPeripheral) async throws {
        // Buttons, receipts and anything else that notifies, except firmware update.
        for (uuid, c) in characteristics where c.service?.uuid != SAB.dfuService && c.service?.uuid != SAB.Security.service {
            guard uuid != SAB.Assignment.control,
                  c.properties.contains(.notify) || c.properties.contains(.indicate) else { continue }
            do {
                try await setNotify(c)
                note("Listening to \(SAB.name(of: uuid))")
            } catch {
                note("Could not listen to \(SAB.name(of: uuid)): \(error)", error: true)
            }
        }
    }

    // MARK: Async GATT helpers

    @MainActor
    private func read(_ c: CBCharacteristic) async throws -> Data {
        try await withTimeout(20, "read \(SAB.name(of: c.uuid))") {
            try await withCheckedThrowingContinuation { cont in
                self.readWaiters[c.uuid] = cont
                c.service?.peripheral?.readValue(for: c)
            }
        }
    }

    @MainActor
    private func write(_ data: Data, to c: CBCharacteristic) async throws {
        guard let p = c.service?.peripheral else { throw GATTError(description: "no peripheral") }
        if c.properties.contains(.write) {
            try await withTimeout(20, "write \(SAB.name(of: c.uuid))") {
                try await withCheckedThrowingContinuation { cont in
                    self.writeWaiters[c.uuid] = cont
                    p.writeValue(data, for: c, type: .withResponse)
                }
            }
        } else {
            p.writeValue(data, for: c, type: .withoutResponse)
        }
    }

    @MainActor
    private func setNotify(_ c: CBCharacteristic) async throws {
        try await withTimeout(20, "subscribe \(SAB.name(of: c.uuid))") {
            try await withCheckedThrowingContinuation { cont in
                self.notifyStateWaiters[c.uuid] = cont
                c.service?.peripheral?.setNotifyValue(true, for: c)
            }
        }
    }

    @MainActor
    private func nextNotification(on c: CBCharacteristic, timeout: Double) async throws -> Data {
        if var buffered = notificationBuffer[c.uuid], !buffered.isEmpty {
            let first = buffered.removeFirst()
            notificationBuffer[c.uuid] = buffered
            return first
        }
        return try await withTimeout(timeout, "notification on \(SAB.name(of: c.uuid))") {
            try await withCheckedThrowingContinuation { cont in
                self.notificationWaiters[c.uuid] = cont
            }
        }
    }

    /// Races `operation` against a timer; on timeout, fails every waiter so nothing leaks.
    @MainActor
    private func withTimeout<T>(_ seconds: Double, _ what: String, _ operation: @escaping () async throws -> T) async throws -> T {
        let timer = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.failAllWaiters(GATTError(description: "timed out: \(what)"))
        }
        defer { timer.cancel() }
        return try await operation()
    }

    private func failAllWaiters(_ error: Error) {
        readWaiters.values.forEach { $0.resume(throwing: error) }
        writeWaiters.values.forEach { $0.resume(throwing: error) }
        notifyStateWaiters.values.forEach { $0.resume(throwing: error) }
        notificationWaiters.values.forEach { $0.resume(throwing: error) }
        discoveryWaiter?.resume(throwing: error)
        readWaiters = [:]; writeWaiters = [:]; notifyStateWaiters = [:]; notificationWaiters = [:]; discoveryWaiter = nil
    }

    private func note(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }
}

// MARK: - CBCentralManagerDelegate

extension SABClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            note("Bluetooth on")
            autoConnect()
        case .unauthorized: note("Bluetooth permission denied. Allow it in Settings → ScooterLink.", error: true)
        case .poweredOff: note("Bluetooth is off", error: true)
        default: note("Bluetooth state \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        restored.delegate = self
        connectedName = restored.name
        note("Relaunched by iOS for the scooter (\(restored.state == .connected ? "connected" : "pending"))")
        if restored.state == .connected {
            flow = Task { @MainActor in await self.runFlow(restored) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let isHonda = services.contains { SAB.customServices.contains($0) || $0 == SAB.dfuService }
            || (name ?? "").localizedCaseInsensitiveContains("honda")
        guard isHonda || name != nil else { return }
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
            devices[i].isHonda = devices[i].isHonda || isHonda
        } else {
            devices.append(ScannedScooter(peripheral: peripheral, name: name ?? "Unnamed", rssi: RSSI.intValue, isHonda: isHonda))
            if isHonda {
                note("Found \(name ?? "device") advertising \(services.map(SAB.name(of:)).joined(separator: ", "))")
                if autoPickFirstHonda, let found = devices.last { connect(found) }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("Connected (MTU for writes: \(peripheral.maximumWriteValueLength(for: .withResponse)) bytes)")
        flow?.cancel()
        flow = Task { @MainActor in await self.runFlow(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        phase = .failed
        note("Connection failed: \(error?.localizedDescription ?? "unknown")", error: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        flow?.cancel()
        stopScreenLoop()
        failAllWaiters(GATTError(description: "disconnected"))
        if phase != .failed { phase = .idle }
        dashMode = .unknown
        readyAt = nil
        note("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")", error: error != nil)
        // Ignition off: keep a pending connect so we come back on our own next ride.
        if !userDisconnected {
            central.connect(peripheral)
            note("Will reconnect when the scooter is back")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SABClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { discoveryWaiter?.resume(throwing: error); discoveryWaiter = nil; return }
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { discoveryWaiter?.resume(); discoveryWaiter = nil }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { note("Characteristics of \(SAB.name(of: service.uuid)) failed: \(error.localizedDescription)", error: true) }
        pendingServices -= 1
        if pendingServices == 0 { discoveryWaiter?.resume(); discoveryWaiter = nil }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let waiter = readWaiters.removeValue(forKey: c.uuid) {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: c.value ?? Data()) }
            return
        }
        guard error == nil, let value = c.value else { return }
        if c.uuid == SAB.DataCommunication.functionSource, let byte = value.first {
            let press = ButtonPress(raw: byte)
            let wasOnPhoneScreen = dashMode == .phone
            presses.insert(press, at: 0)
            note("🔘 BUTTON \(press.function?.label ?? "unknown") (\(value.hex))")
            switch press.function {
            case .modeSAB:
                dashMode = .phone
                Task { @MainActor in self.startScreenLoop() }
            case .modeHU:
                dashMode = .scooter
            case .volumeMute where dashMode != .phone:
                // The dash still sends Mute on its own screen: use it to bring ours back.
                ensurePhoneScreen()
            default:
                break
            }
            if let function = press.function {
                // Holding a button makes the dash repeat it every ~0.2-0.4 s: act once per press.
                if let last = lastAction, last.function == function, Date().timeIntervalSince(last.at) < 0.45 {
                    lastAction = (function, Date())
                    return
                }
                lastAction = (function, Date())
                // On the scooter's own screen Mute only brings the phone screen back.
                if function == .volumeMute && !wasOnPhoneScreen { return }
                ButtonActions.handle(function) { [weak self] in self?.note("   ↳ \($0)") }
                if Features.drawOnDash {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        self?.pushScreen()
                    }
                }
            }
            return
        }
        if c.uuid == SAB.DataCommunication.controlPoint {
            handleReceipt(value)
            return
        }
        if c.uuid == CBUUID(string: "2A19") {
            // The dash pings every 10 s: a free moment to catch play-state changes.
            retryPhoneScreenIfNeeded()
            if Features.drawOnDash { Task { @MainActor in self.pushScreen() } }
            return
        }
        if let waiter = notificationWaiters.removeValue(forKey: c.uuid) {
            waiter.resume(returning: value)
        } else if c.uuid == SAB.Assignment.control {
            notificationBuffer[c.uuid, default: []].append(value)
        } else {
            note("⇠ \(SAB.name(of: c.uuid)): \(value.hex)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let waiter = writeWaiters.removeValue(forKey: c.uuid) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let waiter = notifyStateWaiters.removeValue(forKey: c.uuid) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}

extension CBCharacteristicProperties {
    var short: String {
        var parts: [String] = []
        if contains(.read) { parts.append("read") }
        if contains(.write) { parts.append("write") }
        if contains(.writeWithoutResponse) { parts.append("write-nr") }
        if contains(.notify) { parts.append("notify") }
        if contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

/// The scooter's AES key, kept in the Keychain per scooter.
enum KeyStore {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "scooterlink") + ".key",
         kSecAttrAccount as String: id.uuidString]
    }

    static func load(for id: UUID) -> Data? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func save(_ key: Data, for id: UUID) {
        delete(for: id)
        var q = query(id)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
