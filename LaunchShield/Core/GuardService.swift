import Foundation
import AVFoundation
import AVKit
import UIKit
import UserNotifications

/// Background keep-alive built on the public AVKit video-call PiP (iOS 15+).
/// A tiny, nearly invisible PiP window keeps this process scheduled while the
/// user is in another app. The guard loop only asks for file sizes (stat), so
/// it costs very little power; it never reads file contents.
///
/// This is not a permanent daemon: if the system reclaims the app or the user
/// closes the PiP window, the guard stops, and the next launch says when it
/// was interrupted instead of pretending it kept running.
final class GuardService: NSObject, ObservableObject {

    static let shared = GuardService()

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "未开启"
    @Published private(set) var interruption: Date?
    /// Optional extra: a silent audio loop after locking (off by default).
    var silentBoost: Bool {
        get { defaults.bool(forKey: Keys.silentBoost) }
        set {
            defaults.set(newValue, forKey: Keys.silentBoost)
            objectWillChange.send()
            if isRunning { applySilentBoost() }
        }
    }

    /// 被挤通知：画中画被别的 App 占掉或被系统收回、守护意外停下时发一条
    /// 本地通知（默认开）。用户自己在界面里关守护不发。
    var squeezeNotify: Bool {
        get { defaults.object(forKey: Keys.squeezeNotify) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.squeezeNotify)
            objectWillChange.send()
        }
    }

    var log: ((String, LogLevel) -> Void)?
    /// Called from the guard queue: `deep` asks for the 30-second directory
    /// comparison in addition to the 3-second size check.
    var poll: ((_ deep: Bool) -> Void)?

    private enum Keys {
        static let active = "guard.active"
        static let heartbeat = "guard.heartbeat"
        static let interruption = "guard.interruption"
        static let silentBoost = "guard.silentBoost"
        static let squeezeNotify = "guard.squeezeNotify"
    }

    private let defaults = UserDefaults.standard
    private weak var anchorView: UIView?
    private var pipController: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var captureSession: AVCaptureSession?
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var stopping = false
    private var silentPlayer: AVAudioPlayer?

    override init() {
        super.init()
        // A session marked active at launch was killed while it was running.
        if defaults.bool(forKey: Keys.active) {
            let when = defaults.object(forKey: Keys.heartbeat) as? Date ?? Date()
            interruption = when
            defaults.set(when, forKey: Keys.interruption)
            defaults.set(false, forKey: Keys.active)
            defaults.removeObject(forKey: Keys.heartbeat)
        } else if let stored = defaults.object(forKey: Keys.interruption) as? Date {
            interruption = stored
        }
    }

    // MARK: - Lifecycle

    /// The tiny host view PiP animates from; it must be in a window.
    func attach(_ view: UIView) {
        anchorView = view
    }

    /// Returns nil when PiP was asked to start, or a Chinese reason.
    /// `hidden` starts the PiP window at 0.1pt height (fully hidden), the
    /// same trick the global-refresh PiP apps use.
    func start(hidden: Bool = false) -> String? {
        if isRunning { return nil }
        guard anchorView?.window != nil else {
            return "首页还没显示出来，请等页面出现后再开启守护"
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return "这台设备不支持画中画，守护模式用不了"
        }
        stopping = false
        interruption = nil
        defaults.removeObject(forKey: Keys.interruption)
        prepareAudioSession()
        startCapture()
        guard startPictureInPicture(hidden: hidden) else {
            stopCapture()
            return "画中画没能启动：请确认系统设置里允许画中画，再试一次"
        }
        isRunning = true
        statusText = "守护中"
        tickCount = 0
        defaults.set(true, forKey: Keys.active)
        defaults.set(Date(), forKey: Keys.heartbeat)
        startTimer()
        applySilentBoost()
        return nil
    }

    func stop() {
        stopping = true
        defaults.set(false, forKey: Keys.active)
        defaults.removeObject(forKey: Keys.heartbeat)
        timer?.cancel()
        timer = nil
        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        callViewController = nil
        stopCapture()
        silentPlayer?.stop()
        silentPlayer = nil
        if isRunning {
            isRunning = false
            statusText = "未开启"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - PiP

    /// 窗口大小由内容控制器的 preferredContentSize 决定：画面必须透明、
    /// 铺满，系统才按给的尺寸走；高度压到 0.1 时窗口等于完全隐藏。
    /// 之前塞一个 8×8 黑块、画面没铺满，系统拿不到尺寸，就给了默认大黑窗。
    private func startPictureInPicture(hidden: Bool) -> Bool {
        guard let anchor = anchorView else { return false }
        let controller = AVPictureInPictureVideoCallViewController()
        controller.preferredContentSize = CGSize(width: 300, height: hidden ? 0.1 : 160)
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        let content = UIView(frame: controller.view.bounds)
        content.backgroundColor = .clear
        content.isOpaque = false
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(content)
        callViewController = controller

        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: anchor,
                                                               contentViewController: controller)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
        pip.startPictureInPicture()
        return true
    }

    /// 守护运行中把窗口压到 0.1（完全隐藏）或恢复成小窗。
    func setPiPHidden(_ hidden: Bool) {
        callViewController?.preferredContentSize = CGSize(width: 300, height: hidden ? 0.1 : 160)
    }

    // MARK: - Notifications

    /// 首次打开时请一次通知权限（被挤通知要用）。已经问过就不重复弹。
    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static func postSqueezeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "守护被挤掉了"
        content.body = "画中画被其他应用占用或被系统收回，守护已停。回来重新开启就能继续。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "guard-squeezed-\(Int(Date().timeIntervalSince1970))",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .videoChat,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            log?("设置音频会话失败：\(error.localizedDescription)", .warning)
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard !granted else { return }
                DispatchQueue.main.async {
                    self?.log?("麦克风权限没开，画中画保活可能启动不了；本应用不录音、不上传声音", .notice)
                }
            }
        } else {
            session.requestRecordPermission { _ in }
        }
    }

    private func startCapture() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        if let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopCapture() {
        guard let session = captureSession else { return }
        captureSession = nil
        DispatchQueue.global(qos: .utility).async {
            session.stopRunning()
        }
    }

    // MARK: - Guard loop

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.sociart.launchshield.guard"))
        source.schedule(deadline: .now() + 3, repeating: 3)
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.tickCount += 1
            if self.tickCount % 5 == 0 {
                self.defaults.set(Date(), forKey: Keys.heartbeat)
            }
            self.poll?(self.tickCount % 10 == 0)
        }
        source.resume()
        timer = source
    }

    // MARK: - Optional silent audio

    private func applySilentBoost() {
        silentPlayer?.stop()
        silentPlayer = nil
        guard silentBoost, isRunning, let data = GuardService.silentWAV() else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            silentPlayer = player
        } catch {
            log?("静音音频补强没启动：\(error.localizedDescription)", .notice)
        }
    }

    /// One second of 8-bit mono silence; only keeps the audio session busy.
    private static func silentWAV() -> Data? {
        var data = Data()
        let sampleRate: UInt32 = 8000
        let samples: UInt32 = 8000

        func append(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func appendLE(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        appendLE(36 + samples)
        append("WAVE")
        append("fmt ")
        appendLE(16)
        appendLE(1)              // PCM
        appendLE(1)              // mono
        appendLE(sampleRate)
        appendLE(sampleRate)     // byte rate
        appendLE(1)              // block align
        appendLE(8)              // bits per sample
        append("data")
        appendLE(samples)
        data.append(contentsOf: repeatElement(UInt8(0x80), count: Int(samples)))
        return data
    }
}

extension GuardService: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isRunning = true
            self.statusText = "守护中"
            self.log?("画中画已启动，守护在后台继续", .success)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.statusText = "已中断"
            if self.stopping {
                self.stopping = false
                return
            }
            let when = Date()
            self.interruption = when
            self.defaults.set(when, forKey: Keys.interruption)
            self.defaults.set(false, forKey: Keys.active)
            self.log?("守护已中断（画中画被关掉或被系统收回）", .warning)
            if self.squeezeNotify {
                GuardService.postSqueezeNotification()
            }
            self.timer?.cancel()
            self.timer = nil
            self.stopCapture()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.statusText = "没启动"
            self.defaults.set(false, forKey: Keys.active)
            self.timer?.cancel()
            self.timer = nil
            self.stopCapture()
            self.log?("画中画启动失败：\(error.localizedDescription)", .warning)
        }
    }
}
