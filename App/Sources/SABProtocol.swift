import CoreBluetooth

/// Honda RoadSync ("SAB") BLE protocol constants, taken from the decompiled
/// RoadSync Android app 26.8.10 (com.honda.ms.dm.sab.entity.SAB). See FINDINGS.txt.
enum SAB {
    enum Security {
        static let service = CBUUID(string: "592C1017-9C7B-4A35-ABA6-F268592FB8FC")
        static let controlPoint = CBUUID(string: "4FA28B27-6938-48F8-980E-7C7C9ACC6C1E")
        static let dataSource = CBUUID(string: "EBB3656F-03A5-44CE-A22C-70CFCCF5E247")
        static let status = CBUUID(string: "A65B7152-589E-4933-A426-8F729BFAD439")

        static let secureExchange: UInt8 = 0x02
        static let validation: UInt8 = 0x03
    }

    enum DataCommunication {
        static let service = CBUUID(string: "8536E103-6771-4D4B-9702-287CB5E1340F")
        static let controlPoint = CBUUID(string: "D2E23443-F1AD-4293-A70B-A9FD163F7B00")
        static let drivingInfo = CBUUID(string: "BB1D5836-BF35-11ED-AFA1-0242AC120002")
        static let functionSource = CBUUID(string: "6C060578-D1D9-460A-B86F-EB97F01B2227")

        static let requestSABMode: UInt8 = 0x0A
    }

    enum Assignment {
        static let service = CBUUID(string: "F0746E98-61D6-4570-BE7E-7635C65C21CB")
        static let control = CBUUID(string: "4F5FBE6B-474B-4820-833F-95BFBF525D9F")

        static let end: [UInt8] = [0x03]
    }

    enum VehicleInformation {
        static let service = CBUUID(string: "4D87B1EA-528B-4798-B002-E2E1442A2E86")
        static let characteristics: [(CBUUID, String)] = [
            (CBUUID(string: "5738696D-45B3-475F-81D8-CC685D56EC18"), "VehicleType"),
            (CBUUID(string: "0AD39E0B-B78D-4252-9917-1AA31A915DA7"), "DisplayCapability"),
            (CBUUID(string: "DDD14E97-636D-4338-A798-94CF7CE13667"), "SwitchType"),
            (CBUUID(string: "3F033888-0211-472E-9405-6525D4E4DDC7"), "CategoryId"),
            (CBUUID(string: "5074E0E8-006F-41AC-AA0F-DE6E4649A830"), "SeriesCode"),
            (CBUUID(string: "55F7910B-8CDA-458B-9B54-8A7DA8CD79D4"), "DestinationId"),
        ]
    }

    /// Firmware update service. Never written to.
    static let dfuService = CBUUID(string: "0EA1BD92-5C48-41AD-9B8F-70DA1BD08F35")

    static let customServices: [CBUUID] = [
        Security.service, DataCommunication.service, Assignment.service, VehicleInformation.service,
    ]

    static func name(of uuid: CBUUID) -> String {
        switch uuid {
        case Security.service: return "Security"
        case Security.controlPoint: return "Security.ControlPoint"
        case Security.dataSource: return "Security.DataSource"
        case Security.status: return "Security.Status"
        case DataCommunication.service: return "Data"
        case DataCommunication.controlPoint: return "Data.ControlPoint"
        case DataCommunication.drivingInfo: return "Data.DrivingInfo"
        case DataCommunication.functionSource: return "Data.Buttons"
        case Assignment.service: return "Assignment"
        case Assignment.control: return "Assignment.Control"
        case VehicleInformation.service: return "VehicleInfo"
        case dfuService: return "DFU (firmware)"
        default:
            return VehicleInformation.characteristics.first { $0.0 == uuid }.map { "VehicleInfo.\($0.1)" }
                ?? uuid.uuidString
        }
    }
}

/// One byte per handlebar press on Data.Buttons (Assignments.FunctionId, value = ordinal + 1).
enum ButtonFunction: UInt8, CaseIterable {
    case previous = 1, next, back, select, volumeUp, volumeDown, volumeMute, menu, modeSAB, modeHU

    var label: String {
        switch self {
        case .previous: return L("Previous")
        case .next: return L("Next")
        case .back: return L("Back")
        case .select: return L("Select")
        case .volumeUp: return L("Volume +")
        case .volumeDown: return L("Volume −")
        case .volumeMute: return L("Mute")
        case .menu: return L("Menu")
        case .modeSAB: return L("Mode: phone screen")
        case .modeHU: return L("Mode: scooter screen")
        }
    }

    var symbol: String {
        switch self {
        case .previous: return "backward.fill"
        case .next: return "forward.fill"
        case .back: return "arrow.uturn.backward"
        case .select: return "circle.inset.filled"
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        case .volumeMute: return "speaker.slash.fill"
        case .menu: return "line.3.horizontal"
        case .modeSAB: return "iphone"
        case .modeHU: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// Button-function registrations sent to Assignment.Control at connect
/// (AssignmentBuilder.a). Request IDs are 16-bit, written low byte first.
enum Assignments {
    private static let colors: [(id: UInt8, rgb: [UInt8])] = [
        (2, [0xD6, 0x47, 0x47]), (3, [0x38, 0xA8, 0x43]),                         // negative, positive
        (4, [0x30, 0x9A, 0x87]), (5, [0x24, 0x73, 0x65]), (6, [0x0B, 0x27, 0x22]), // greens
        (7, [0x78, 0x46, 0xA3]), (8, [0x57, 0x32, 0x7A]), (9, [0x27, 0x16, 0x37]), // purples
        (10, [0x45, 0x7A, 0xB1]), (11, [0x34, 0x5C, 0x86]), (12, [0x12, 0x1F, 0x2C]), // blues
        (13, [0xD8, 0x84, 0x2B]), (14, [0xAA, 0x69, 0x27]), (15, [0x4C, 0x28, 0x0A]), // oranges
        (16, [0x71, 0x71, 0x71]), (17, [0x4B, 0x4B, 0x4B]), (18, [0x27, 0x27, 0x27]), // greys
    ]

    /// `theme` replaces RoadSync's orange family (slots 13 light, 14 main, 15 dark), which the
    /// Ride screen uses. The dash keeps the first colours registered after ignition-on.
    static func all(includeColors: Bool, theme: (main: [UInt8], dark: [UInt8], light: [UInt8])? = nil) -> [[UInt8]] {
        var requestId: UInt16 = 0
        func nextId() -> [UInt8] {
            requestId &+= 1
            return [UInt8(requestId & 0xFF), UInt8(requestId >> 8)]
        }
        var list: [[UInt8]] = [
            [0x01] + nextId() + [ButtonFunction.volumeUp.rawValue, 1, 7, 0x80, 0],
            [0x01] + nextId() + [ButtonFunction.volumeDown.rawValue, 1, 7, 0x81, 0],
        ]
        for function in [ButtonFunction.previous, .next, .back, .select, .volumeMute, .menu, .modeSAB, .modeHU] {
            list.append([0x01] + nextId() + [function.rawValue, 2])
        }
        if includeColors {
            for color in colors {
                var rgb = color.rgb
                if let theme {
                    switch color.id {
                    case 13: rgb = theme.light
                    case 14: rgb = theme.main
                    case 15: rgb = theme.dark
                    default: break
                    }
                }
                list.append([0x02] + nextId() + [color.id] + rgb)
            }
        }
        return list
    }

    /// AssignmentResult: [command, requestId lo, requestId hi, status, errorPosition?]
    static func describeResult(_ data: Data) -> String {
        guard data.count >= 4 else { return "short result \(data.hex)" }
        let status = data[data.startIndex + 3]
        switch status {
        case 1: return "OK"
        case 13: return "already registered (OK)"
        case 11: return "INVALID ID"
        case 12: return "INVALID PARAMETERS at \(data.count > 4 ? String(data[data.startIndex + 4]) : "?")"
        default: return "status \(status)"
        }
    }

    static func isFailure(_ data: Data) -> Bool {
        guard data.count >= 4 else { return true }
        let status = data[data.startIndex + 3]
        return status != 1 && status != 13
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
