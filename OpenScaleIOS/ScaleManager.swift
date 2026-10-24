// SPDX-License-Identifier: GPL-3.0-or-later
//
// OpenTara – lokale Körperwaagen-App

import Foundation
import CoreBluetooth

/// Sucht per BLE nach unterstützten Waagen und wertet sie über die registrierten
/// `ScaleDriver` aus – passiv (Advertisement) oder per Verbindung (GATT).
final class ScaleManager: NSObject, ObservableObject {

    @Published var statusText: String = String(localized: "Starte…")
    @Published var isScanning: Bool = false
    @Published var bluetoothReady: Bool = false

    @Published var lastWeightKg: Double?
    @Published var lastImpedance: Int?
    @Published var lastStabilized: Bool = false
    @Published var lastRawHex: String = ""
    @Published var lastDeviceName: String = ""
    @Published var log: [String] = []

    /// Name der Waage, mit der gerade eine GATT-Verbindung steht (nil = keine).
    @Published var connectedDeviceName: String?
    /// Der verbundene Treiber kann gerade auf Knopfdruck eine Messung auslösen.
    @Published var canTriggerMeasurement: Bool = false
    /// Gemerkte Waage (nach der ersten erfolgreichen Verbindung). Beim nächsten Start wird sie
    /// ohne Suche per wartender Verbindung angesprochen, sobald sie sendet.
    @Published var rememberedDeviceName: String?

    /// Wird aufgerufen, sobald eine stabilisierte Messung eintrifft.
    var onStabilizedMeasurement: ((ScaleMeasurement) -> Void)?

    /// Profil + Einheit der Person, die sich wiegt. Vor `startScan()` setzen; Treiber mit
    /// Nutzerverwaltung auf der Waage (Beurer/Sanitas) brauchen es, alle anderen ignorieren es.
    var userContext: ScaleUserContext?

    private var central: CBCentralManager!
    private let drivers = ScaleDriverRegistry.all

    // Aktive Verbindung (für Verbindungs-Treiber)
    private var activePeripheral: CBPeripheral?
    private var activeDriver: ScaleDriver?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyingCount = 0
    private var driverReady = false
    private var activeDeviceName: String?

    private let rememberedIdKey = "openscale.scale.peripheralId.v1"
    private let rememberedNameKey = "openscale.scale.peripheralName.v1"

    override init() {
        super.init()
        rememberedDeviceName = UserDefaults.standard.string(forKey: rememberedNameKey)
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            statusText = String(localized: "Bluetooth nicht bereit")
            return
        }
        log.removeAll()
        isScanning = true
        if let (peripheral, driver, name) = rememberedPeripheral() {
            // Gekoppelt: wartende Verbindung, iOS verbindet, sobald die Waage sendet.
            waitFor(peripheral, driver: driver, name: name)
            statusText = String(localized: "Gekoppelt mit \(name) – wartet auf die Waage (zum Wecken drauftippen)")
        } else {
            statusText = String(localized: "Suche Waage… jetzt barfuß draufstellen")
        }
        // Die Suche läuft zusätzlich, damit eine neue/andere Waage gefunden wird.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// Löst beim verbundenen Treiber eine Messung aus (Knopf „Jetzt wiegen“).
    func triggerMeasurement() {
        guard driverReady, let driver = activeDriver else { return }
        driver.requestMeasurement(makeLink())
        refreshTriggerState()
    }

    /// Vergisst die gemerkte Waage; die nächste Suche läuft wieder offen.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: rememberedIdKey)
        UserDefaults.standard.removeObject(forKey: rememberedNameKey)
        rememberedDeviceName = nil
        if isScanning { stopScan() }
    }

    private func rememberedPeripheral() -> (CBPeripheral, ScaleDriver, String)? {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: rememberedIdKey), let id = UUID(uuidString: idString),
              let name = defaults.string(forKey: rememberedNameKey),
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first,
              let driver = drivers.first(where: {
                  $0.kind == .connection && $0.matches(name: name, serviceData: [:], advertised: [])
              })
        else { return nil }
        return (peripheral, driver, name)
    }

    private func remember(_ peripheral: CBPeripheral, name: String) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: rememberedIdKey)
        UserDefaults.standard.set(name, forKey: rememberedNameKey)
        rememberedDeviceName = name
    }

    /// Wartende Verbindung zu einer bekannten Waage (ohne Suche; iOS verbindet beim nächsten Senden).
    private func waitFor(_ peripheral: CBPeripheral, driver: ScaleDriver, name: String) {
        activeDriver = driver
        activePeripheral = peripheral
        activeDeviceName = name
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        appendLog("warte auf [\(driver.displayName)] \(name)")
    }

    private func refreshTriggerState() {
        let can = driverReady && (activeDriver?.canRequestMeasurement ?? false)
        DispatchQueue.main.async { self.canTriggerMeasurement = can }
    }

    func stopScan() {
        central.stopScan()
        if let p = activePeripheral { central.cancelPeripheralConnection(p) }
        activeDriver?.onDisconnected()
        clearConnection()
        isScanning = false
        statusText = String(localized: "Scan gestoppt")
    }

    private func clearConnection() {
        activePeripheral = nil
        activeDriver = nil
        activeDeviceName = nil
        writeCharacteristic = nil
        notifyingCount = 0
        driverReady = false
        DispatchQueue.main.async {
            self.connectedDeviceName = nil
            self.canTriggerMeasurement = false
        }
    }

    private func appendLog(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    private static func hex(_ data: Data) -> String {
        [UInt8](data).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func handle(_ reading: ScaleReading) {
        lastRawHex = reading.rawHex
        lastWeightKg = reading.weightKg
        lastImpedance = reading.impedance
        lastStabilized = reading.isStabilized
        lastDeviceName = reading.source

        statusText = String(
            format: "%.2f kg%@%@",
            reading.weightKg,
            reading.isStabilized ? " ✓ stabil" : " …",
            reading.impedance != nil ? " · Imp \(reading.impedance!)Ω" : " · barfuß fehlt"
        )
        appendLog(String(
            format: "[%@] w=%.2f imp=%@ stab=%d  %@",
            reading.source, reading.weightKg, reading.impedance.map(String.init) ?? "-",
            reading.isStabilized ? 1 : 0, reading.rawHex
        ))

        if reading.isStabilized && !reading.weightRemoved {
            let m = ScaleMeasurement(
                date: reading.date ?? Date(),
                weightKg: reading.weightKg,
                impedance: reading.impedance,
                isStabilized: true,
                rawHex: reading.rawHex
            )
            onStabilizedMeasurement?(m)
        }
    }

    // MARK: - Rückkanal für Verbindungs-Treiber

    private func makeLink() -> ScaleDriverLink {
        ScaleDriverLink(
            user: userContext,
            send: { [weak self] data in self?.write(data) },
            log: { [weak self] line in
                DispatchQueue.main.async { self?.appendLog(line) }
            },
            status: { [weak self] text in
                DispatchQueue.main.async { self?.statusText = text }
            }
        )
    }

    private func write(_ data: Data) {
        guard let peripheral = activePeripheral, let ch = writeCharacteristic else {
            DispatchQueue.main.async { self.appendLog("→ (verworfen, keine Schreib-Characteristic) \(Self.hex(data))") }
            return
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: ch, type: type)
        DispatchQueue.main.async { self.appendLog("→ \(Self.hex(data))") }
    }

    /// Ruft `onReady` genau einmal, sobald mindestens eine Notification aktiv ist und die
    /// Schreib-Characteristic (falls der Treiber eine will) gefunden wurde.
    private func startDriverIfReady() {
        guard !driverReady, let driver = activeDriver, let profile = driver.connectionProfile else { return }
        guard notifyingCount > 0 || profile.notifyUUIDs.isEmpty else { return }
        if profile.writeUUID != nil && writeCharacteristic == nil { return }
        driverReady = true
        if let p = activePeripheral {
            let name = activeDeviceName ?? p.name ?? driver.displayName
            remember(p, name: name)
            DispatchQueue.main.async { self.connectedDeviceName = name }
        }
        driver.onReady(makeLink())
        refreshTriggerState()
    }
}

// MARK: - Central (Scan + Verbindungsaufbau)

extension ScaleManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothReady = true
            statusText = String(localized: "Bluetooth bereit – auf Suchen tippen")
        case .poweredOff:
            bluetoothReady = false
            statusText = String(localized: "Bluetooth ist ausgeschaltet")
        case .unauthorized:
            bluetoothReady = false
            statusText = String(localized: "Bluetooth-Berechtigung fehlt (Einstellungen)")
        case .unsupported:
            bluetoothReady = false
            statusText = String(localized: "Bluetooth wird nicht unterstützt")
        default:
            bluetoothReady = false
            statusText = String(localized: "Bluetooth nicht verfügbar")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        // 1) Advertisement-Treiber: Daten stecken schon im Broadcast.
        for driver in drivers where driver.kind == .advertisement
            && driver.matches(name: name, serviceData: serviceData, advertised: advertised) {
            if let reading = driver.parse(serviceData: serviceData, localName: name) {
                DispatchQueue.main.async { self.handle(reading) }
                return
            }
        }

        // 2) Verbindungs-Treiber: koppeln und GATT abonnieren (nur eine Verbindung zugleich).
        guard activePeripheral == nil else { return }
        for driver in drivers where driver.kind == .connection
            && driver.matches(name: name, serviceData: serviceData, advertised: advertised) {
            activeDriver = driver
            activePeripheral = peripheral
            activeDeviceName = name
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            let label = name ?? peripheral.identifier.uuidString
            DispatchQueue.main.async {
                self.statusText = String(localized: "Verbinde mit \(label)…")
                self.appendLog("verbinde [\(driver.displayName)] \(label)")
            }
            return
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        writeCharacteristic = nil
        notifyingCount = 0
        driverReady = false
        peripheral.discoverServices(activeDriver?.connectionProfile?.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { self.appendLog("Verbindung fehlgeschlagen") }
        clearConnection()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == activePeripheral {
            let driver = activeDriver
            let name = activeDeviceName
            driver?.onDisconnected()
            clearConnection()
            let reason = error.map { ": \($0.localizedDescription)" } ?? ""
            DispatchQueue.main.async { self.appendLog("getrennt\(reason)") }
            // Sitzung läuft weiter: auf die nächste Weckung der Waage warten (Beurer schläft
            // nach der Messung ein und sendet erst wieder, wenn man drauftippt).
            if isScanning, let driver, driverReady == false {
                let label = name ?? peripheral.name ?? driver.displayName
                waitFor(peripheral, driver: driver, name: label)
                DispatchQueue.main.async {
                    self.statusText = String(localized: "\(label) schläft – zum Wiegen drauftippen, die Verbindung kommt von selbst")
                }
            }
        }
    }
}

// MARK: - Peripheral (GATT-Discovery + Notifications)

extension ScaleManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let profile = activeDriver?.connectionProfile
        let notify = profile?.notifyUUIDs ?? []
        for ch in service.characteristics ?? [] {
            if let w = profile?.writeUUID, ch.uuid == w {
                writeCharacteristic = ch
            }
            if notify.contains(ch.uuid) {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        startDriverIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.appendLog("Notify \(characteristic.uuid.uuidString) fehlgeschlagen: \(error.localizedDescription)")
            }
            return
        }
        if characteristic.isNotifying {
            notifyingCount += 1
            startDriverIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.appendLog("Schreiben auf \(characteristic.uuid.uuidString) fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver = activeDriver, let data = characteristic.value else { return }
        let hex = Self.hex(data)
        DispatchQueue.main.async { self.appendLog("← \(characteristic.uuid.uuidString): \(hex)") }
        let link = makeLink()
        if let reading = driver.handle(characteristic: characteristic.uuid, data: data, link: link) {
            DispatchQueue.main.async { self.handle(reading) }
        }
        refreshTriggerState()
    }
}
