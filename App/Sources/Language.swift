import Foundation

/// The language the app speaks, chosen in the ⋯ menu. "System" follows the iPhone's language:
/// Turkish if the phone is set to Turkish, English otherwise. The protocol log stays in English.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, turkish

    static let key = "app.language"

    var id: String { rawValue }

    /// Shown in its own language so it can be found whatever is selected.
    var title: String {
        switch self {
        case .system: return L("Phone language")
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    static var selected: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// True when the app should speak Turkish right now.
    static var isTurkish: Bool {
        switch selected {
        case .english: return false
        case .turkish: return true
        case .system: return Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
        }
    }

    /// Locale for dates and relative times ("5 sn önce").
    static var locale: Locale { Locale(identifier: isTurkish ? "tr_TR" : "en_US") }
}

/// Translates an English UI string. Strings without a Turkish entry stay in English.
func L(_ english: String) -> String {
    AppLanguage.isTurkish ? (turkish[english] ?? english) : english
}

private let turkish: [String: String] = [
    // Language menu
    "Language": "Dil",
    "Phone language": "Telefon dili",

    // Home
    "Turn the key and ScooterLink connects by itself. Keep it in the app switcher: iOS won't relaunch an app you swipe away.":
        "Kontağı aç, ScooterLink kendiliğinden bağlanır. Uygulamayı uygulama değiştiricide açık bırak: yukarı kaydırıp kapatırsan iOS onu yeniden başlatmaz.",
    "Waiting for your scooter": "Motor bekleniyor",
    "Turn the ignition on": "Kontağı aç",
    "Looking for your scooter": "Motor aranıyor",
    "Keep the phone close to the bike": "Telefonu motora yakın tut",
    "Connecting…": "Bağlanıyor…",
    "Pairing…": "Eşleşiyor…",
    "Setting up the handlebar buttons": "Gidon tuşları ayarlanıyor",
    "Ready to ride": "Sürüşe hazır",
    "Buttons control your music": "Tuşlar müziği kontrol ediyor",
    "Connected": "Bağlı",
    "Dash is on its own screen. Press Mute to switch": "Ekran kendi menüsünde. Geçmek için Mute'a bas",
    "Something went wrong": "Bir sorun oluştu",
    "Open Diagnostics for details": "Ayrıntılar için Tanılama'yı aç",
    "Show phone screen on dash": "Telefon ekranını göstergede aç",
    "LAST BUTTON": "SON TUŞ",
    "ago": "önce",
    "Press a handlebar button": "Bir gidon tuşuna bas",
    "It shows up here": "Burada görünecek",
    "BUTTONS": "TUŞLAR",
    "Customize": "Özelleştir",
    "DASH SCREEN": "GÖSTERGE EKRANI",
    "BETA": "BETA",
    "Show music on the dash": "Müziği göstergede göster",
    "If the dash stops showing the phone screen after this: turn this off, delete the phone pairing on the dash, forget HONDA BTU in iPhone Bluetooth settings, and pair again.":
        "Bundan sonra göstergede telefon ekranı gelmezse: bunu kapat, göstergede telefon eşleşmesini sil, iPhone Bluetooth ayarlarında HONDA BTU'yu unut ve yeniden eşleştir.",
    "Phone screen": "Telefon ekranı",
    "phone screen": "telefon ekranı",
    "Phone screen on": "Telefon ekranı açıldı",
    "Scooter screen on": "Motor ekranı açıldı",

    // Menu
    "Reconnect": "Yeniden bağlan",
    "Disconnect": "Bağlantıyı kes",
    "Forget scooter key": "Motor anahtarını unut",

    // Button settings
    "Changes apply from the next press, no reconnect needed.": "Değişiklikler bir sonraki basışta geçerli olur, yeniden bağlanmak gerekmez.",
    "Back / Forward 15 s and 30 s work in apps that offer jumps: podcasts, audiobooks, most video apps. Spotify offers them for podcasts, not for songs.":
        "15 ve 30 sn geri/ileri sarma, bunu destekleyen uygulamalarda çalışır: podcast, sesli kitap ve çoğu video uygulaması. Spotify'da podcastlerde çalışır, şarkılarda çalışmaz.",
    "Mute on the scooter's own screen always brings the phone screen back. Its action here runs only while the phone screen is showing.":
        "Motor kendi ekranındayken Mute her zaman telefon ekranını geri getirir. Buradaki eylem sadece telefon ekranı açıkken çalışır.",
    "Menu may stay with the dash on some bikes. Check Diagnostics → Buttons to see whether it reaches the phone.":
        "Bazı motorlarda Menu tuşu göstergede kalabilir. Telefona ulaşıp ulaşmadığını Tanılama → Tuşlar kısmından kontrol et.",
    "Reset to defaults": "Varsayılana dön",
    "Buttons": "Tuşlar",
    "Reset all buttons to their default actions?": "Tüm tuşlar varsayılan eylemlerine dönsün mü?",
    "Reset": "Sıfırla",

    // Button actions
    "Nothing": "Hiçbir şey",
    "Play / pause": "Oynat / duraklat",
    "Play": "Oynat",
    "Pause": "Duraklat",
    "Next track": "Sonraki şarkı",
    "Previous track": "Önceki şarkı",
    "Back 15 s": "15 sn geri",
    "Forward 15 s": "15 sn ileri",
    "Back 30 s": "30 sn geri",
    "Forward 30 s": "30 sn ileri",

    // Handlebar buttons
    "Previous": "Önceki",
    "Next": "Sonraki",
    "Back": "Geri",
    "Select": "Seç",
    "Volume +": "Ses +",
    "Volume −": "Ses −",
    "Mute": "Sessiz",
    "Menu": "Menü",
    "Mode: phone screen": "Mod: telefon ekranı",
    "Mode: scooter screen": "Mod: motor ekranı",

    // Diagnostics
    "Diagnostics": "Tanılama",
    "Devices": "Cihazlar",
    "Log": "Kayıt",
    "No presses yet": "Henüz basılmadı",
    "Connect in Devices, then press each handlebar button.": "Cihazlar'dan bağlan, sonra her gidon tuşuna bas.",
    "Seen so far": "Şimdiye kadar görülen",
    "Unknown": "Bilinmeyen",
    "Stop scanning": "Aramayı durdur",
    "Scan for scooter": "Motoru ara",
    "Show all Bluetooth devices": "Tüm Bluetooth cihazlarını göster",
    "Before the first connect: delete the RoadSync phone pairing on the PCX dashboard, so the scooter accepts this app's key.":
        "İlk bağlantıdan önce: göstergedeki RoadSync telefon eşleşmesini sil, böylece motor bu uygulamanın anahtarını kabul eder.",
    "Found": "Bulunanlar",
    "Share log": "Kaydı paylaş",
    "Copy": "Kopyala",
    "Clear": "Temizle",

    // Dash (folded to plain letters before sending)
    "Music": "Müzik",
    "Playing": "Çalıyor",
    "Paused": "Duraklatıldı",
]
