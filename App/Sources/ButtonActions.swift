import Foundation

/// System-wide media control through the private MediaRemote framework (what Control
/// Center uses). Works on whatever app is playing, if iOS lets a sideloaded app call it.
enum MediaControl {
    /// MRMediaRemoteCommand values (see WebKit's MediaRemoteSPI.h).
    enum Command: UInt32 {
        case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
        case rewind15 = 12, fastForward15 = 13, rewind30 = 14, fastForward30 = 15
        case skipForward = 17, skipBackward = 18
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let sendCommand = symbol("MRMediaRemoteSendCommand", as: SendCommand.self)

    /// Option key for SkipForward/SkipBackward (a CFStringRef exported by MediaRemote).
    private static let skipIntervalKey: CFString? = {
        guard let handle, let pointer = dlsym(handle, "kMRMediaRemoteOptionSkipInterval") else { return nil }
        return pointer.assumingMemoryBound(to: CFString?.self).pointee
    }()

    @discardableResult
    static func send(_ command: Command, options: CFDictionary? = nil) -> String {
        guard let sendCommand else { return "MediaRemote not available" }
        return sendCommand(command.rawValue, options) ? "\(command) sent" : "\(command) REFUSED by iOS"
    }

    /// Jump forward (positive) or back (negative) by `seconds`. Apps such as podcast and
    /// audiobook players register skip commands with their own interval; we ask for ours and
    /// fall back to the fixed 15/30 s commands if the option key isn't there.
    @discardableResult
    static func skip(seconds: Double) -> String {
        if let key = skipIntervalKey {
            let options = [key as String: NSNumber(value: abs(seconds))] as CFDictionary
            return send(seconds > 0 ? .skipForward : .skipBackward, options: options)
        }
        switch (seconds > 0, abs(seconds) >= 30) {
        case (true, false): return send(.fastForward15)
        case (true, true): return send(.fastForward30)
        case (false, false): return send(.rewind15)
        case (false, true): return send(.rewind30)
        }
    }
}

/// What a handlebar button can be set to do (chosen in the app, see `ButtonSettings`).
enum ButtonAction: String, CaseIterable, Identifiable {
    case nothing
    case playPause, play, pause
    case nextTrack, previousTrack
    case back15, forward15, back30, forward30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nothing: return L("Nothing")
        case .playPause: return L("Play / pause")
        case .play: return L("Play")
        case .pause: return L("Pause")
        case .nextTrack: return L("Next track")
        case .previousTrack: return L("Previous track")
        case .back15: return L("Back 15 s")
        case .forward15: return L("Forward 15 s")
        case .back30: return L("Back 30 s")
        case .forward30: return L("Forward 30 s")
        }
    }

    var symbol: String {
        switch self {
        case .nothing: return "minus.circle"
        case .playPause: return "playpause.fill"
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .nextTrack: return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .back15: return "gobackward.15"
        case .forward15: return "goforward.15"
        case .back30: return "gobackward.30"
        case .forward30: return "goforward.30"
        }
    }

    /// Jumps only work in apps that offer them (podcasts, audiobooks, most video apps).
    var needsAppSupport: Bool {
        switch self {
        case .back15, .forward15, .back30, .forward30: return true
        default: return false
        }
    }

    /// Runs the action and returns a line for the log, or nil for `.nothing`.
    func perform() -> String? {
        switch self {
        case .nothing: return nil
        case .playPause: return MediaControl.send(.togglePlayPause)
        case .play: return MediaControl.send(.play)
        case .pause: return MediaControl.send(.pause)
        case .nextTrack: return MediaControl.send(.next)
        case .previousTrack: return MediaControl.send(.previous)
        case .back15: return MediaControl.skip(seconds: -15)
        case .forward15: return MediaControl.skip(seconds: 15)
        case .back30: return MediaControl.skip(seconds: -30)
        case .forward30: return MediaControl.skip(seconds: 30)
        }
    }
}

/// Which action each button runs, saved on the phone (UserDefaults, one key per button).
enum ButtonSettings {
    /// Buttons the rider can set, in the order they're listed in the app.
    static let configurable: [ButtonFunction] = [.select, .back, .next, .previous, .volumeMute, .menu]

    static func key(for function: ButtonFunction) -> String { "button.action.\(function.rawValue)" }

    static func defaultAction(for function: ButtonFunction) -> ButtonAction {
        switch function {
        case .select, .back: return .playPause
        case .next: return .nextTrack
        case .previous: return .previousTrack
        default: return .nothing
        }
    }

    static func action(for function: ButtonFunction) -> ButtonAction {
        guard configurable.contains(function) else { return .nothing }
        let saved = UserDefaults.standard.string(forKey: key(for: function)).flatMap(ButtonAction.init(rawValue:))
        return saved ?? defaultAction(for: function)
    }

    static func resetAll() {
        for function in configurable { UserDefaults.standard.removeObject(forKey: key(for: function)) }
    }
}

/// What each handlebar button does.
enum ButtonActions {
    static func handle(_ function: ButtonFunction, log: @escaping (String) -> Void) {
        if let line = ButtonSettings.action(for: function).perform() { log(line) }
    }
}
