import Foundation
import Security

var failures = 0
func check(_ ok: Bool, _ name: String) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }

// CRC: CRC-16/ARC check value, and the first entries of RoadSync's table (Checksum.java).
check(SABCrypto.crc16(Array("123456789".utf8)) == 0xBB3D, "crc16 ARC check value 0xBB3D")
check(SABCrypto.crc16([1]) == 49345, "crc16 table[1] = 49345 like RoadSync")
check(SABCrypto.crc16LE([3]) == [UInt8(SABCrypto.crc16([3]) & 0xFF), UInt8(SABCrypto.crc16([3]) >> 8)], "crc LE order")

// RSA exchange round trip: simulate the scooter encrypting [pad|key|crc] to our modulus.
let priv = try SABCrypto.makeRSAKey()
let cmd = try SABCrypto.secureExchangeCommand(privateKey: priv)
check(cmd.count == 129 && cmd.first == 0x02, "exchange command = 0x02 + 128-byte modulus (\(cmd.count))")
let aesKey = (0..<16).map { _ in UInt8.random(in: 0...255) }
var block = [UInt8](repeating: 0, count: 110) + aesKey + SABCrypto.crc16LE(aesKey)
block[0] = 0; block[1] = 0x42
let cipher = SecKeyCreateEncryptedData(SecKeyCopyPublicKey(priv)!, .rsaEncryptionRaw, Data(block) as CFData, nil)! as Data
let recovered = try SABCrypto.aesKey(fromExchangeResponse: cipher, privateKey: priv)
check(recovered == Data(aesKey), "AES key recovered from RSA block")

// AES-ECB/PKCS7 against openssl, and a simulated validation answer.
let key = Data((0..<16).map { UInt8($0) })
let enc = try SABCrypto.aes(encrypt: true, key: key, data: Data([3, 1, 2]), padding: true)
print("AESHEX", enc.map { String(format: "%02x", $0) }.joined())
let vcmd = try SABCrypto.validationCommand(key: key)
check(vcmd.count == 18 && vcmd.prefix(2) == Data([1, 0]), "validation command = 01 00 + 16 bytes")
let answer = Data([0x01, 0x00]) + (try SABCrypto.aes(encrypt: true, key: key, data: Data([1, 0x2A, 0, 0, 0]), padding: true))
check(try SABCrypto.checkValidationResponse(answer, key: key) == 42, "validation answer parsed, increment 42")

// Assignments match AssignmentBuilder byte layout.
let a = Assignments.all(includeColors: true)
check(a.count == 27, "27 assignments (10 functions + 17 colours)")
check(a[0] == [1, 1, 0, 5, 1, 7, 0x80, 0], "volume-up assignment bytes")
check(a[2] == [1, 3, 0, 1, 2], "previous assignment bytes")
check(a[10] == [2, 11, 0, 2, 0xD6, 0x47, 0x47], "first colour (negative) bytes")
// Live screen layout (CommandBuilder.f): header + 4 fixed + left + right + content icon + lines.
let screen = LiveScreen(header: "14:32", line1: "47 km/h", line2: "Playing", leftAction: DashIcon.pause, rightAction: DashIcon.next, colors: .theme)
let enc2 = [UInt8](screen.encode(requestId: 7))
// Built in steps: one long `+` chain of literals is too slow for the type checker.
var expected: [UInt8] = [1, 7, 14, 5]
expected += Array("14:32".utf8)
let body: [UInt8] = [0, 2, 14, 1, 1, 4, 0, 13, 2, 1, 5, 0, 13, 15, 0, 7]
expected += body
expected += Array("47 km/h".utf8)
expected += [0, 7] as [UInt8]
expected += Array("Playing".utf8)
expected += [0] as [UInt8]
check(enc2 == expected, "live screen bytes")
let bare = [UInt8](LiveScreen(header: "Hi", line1: nil, line2: nil, leftAction: nil, rightAction: nil, colors: .theme).encode(requestId: 1))
check(bare == [1, 1, 14, 2, 72, 105, 0, 2, 14, 0, 0, 15, 0, 0, 0], "live screen without actions/lines")
check(LiveScreen.clean("Ελλάδα café 🚀 " + String(repeating: "x", count: 40)).count == 30, "text cleaned and capped at 30")
check(String(decoding: LiveScreen.clean("Çalıyor: Şarkı İçin Ğüö"), as: UTF8.self) == "Caliyor: Sarki Icin Guo", "Turkish letters folded to ASCII")
// Language: Turkish and English picks, and a missing entry falls back to English.
UserDefaults.standard.set("turkish", forKey: AppLanguage.key)
check(L("Play / pause") == "Oynat / duraklat" && ButtonFunction.select.label == "Seç", "Turkish labels")
check(L("not translated") == "not translated", "missing entry stays English")
UserDefaults.standard.set("english", forKey: AppLanguage.key)
check(L("Play / pause") == "Play / pause" && ButtonFunction.select.label == "Select", "English labels")
UserDefaults.standard.removeObject(forKey: AppLanguage.key)
let themed = Assignments.all(includeColors: true, theme: Theme(red: 1, green: 0, blue: 0).palette)
check(themed.count == 27 && themed[22] == [2, 23, 0, 14, 255, 0, 0] && themed[21] == [2, 22, 0, 13, 255, 89, 89], "theme replaces orange slots")
exit(failures == 0 ? 0 : 1)
