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
    /// 目录自动处理：守护盯着已确认的广告目录和冷开广告目录，里面一有
    /// 新文件就自动清零冻结（先备份）。默认开。
    var dirWatch: Bool {
        get { defaults.object(forKey: Keys.dirWatch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.dirWatch) }
    }

    var squeezeNotify: Bool {
        get { defaults.object(forKey: Keys.squeezeNotify) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.squeezeNotify)
            objectWillChange.send()
        }
    }

    /// 画中画悬浮高度（pt）：守护开启时窗口就按这个高度显示出来，
    /// 用户在守护卡里拖滑块调，拖动即时生效。隐藏时固定压到 0.1。
    var pipHeight: Double {
        get {
            let stored = defaults.object(forKey: Keys.pipHeight) as? Double ?? 160
            return min(max(stored, 40), 240)
        }
        set {
            defaults.set(min(max(newValue, 40), 240), forKey: Keys.pipHeight)
            objectWillChange.send()
        }
    }

    /// 当前画中画是不是压在 0.1 隐藏着。
    private(set) var pipHidden = false
    /// 一键开启并隐藏：先把窗口显示出来，启动成功后自动压到 0.1。
    private var autoHidePending = false

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
        static let dirWatch = "guard.dirWatch"
        static let pipHeight = "guard.pipHeight"
    }

    private let defaults = UserDefaults.standard
    private weak var pipHostView: UIView?
    /// 画中画专用窗口：源视图放在这个独立窗口里，不放主窗口。
    /// 画中画进出时系统会动源视图所在的那个窗口（缩放/位移做动画），
    /// 源视图在主窗口里时，主界面会被连带弄歪（实测界面整体左移、内容
    /// 被切掉一截，停了守护也不恢复）。独立窗口只用来发现场景和承载
    /// 源视图，透明、不挡触摸。
    private var pipWindow: UIWindow?
    private var pipRootViewController: UIViewController?
    private var pipController: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var pipSourceView: UIView?
    private var pipSourceWidthConstraint: NSLayoutConstraint?
    private var pipSourceHeightConstraint: NSLayoutConstraint?
    private var pipContentView: UIView?
    private var wantsPiPActive = false
    private var pipStartWorkItem: DispatchWorkItem?
    /// 隐藏时窗口压到的高度（照全局高刷的 minPiPHeight）。
    private let minPiPHeight: CGFloat = 0.1
    private let pipWidth: CGFloat = 300
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

    /// 画中画宿主视图（铺满主界面的透明层，照全局高刷的做法：
    /// 源视图建在它里面、居中、和窗口一样大）。它必须在窗口里。
    func attach(_ view: UIView) {
        pipHostView = view
    }

    /// Returns nil when PiP was asked to start, or a Chinese reason.
    /// 守护开启时画中画窗口先按悬浮高度显示出来；`hidden`（一键开启并隐藏）
    /// 是在窗口显示出来、启动成功之后，再自动压到 0.1 藏起来。
    func start(hidden: Bool = false) -> String? {
        if isRunning { return nil }
        guard pipHostView?.window != nil else {
            return "首页还没显示出来，请等页面出现后再开启守护"
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return "这台设备不支持画中画，守护模式用不了"
        }
        stopping = false
        interruption = nil
        autoHidePending = hidden
        pipHidden = false
        defaults.removeObject(forKey: Keys.interruption)
        prepareAudioSession()
        startCapture()
        wantsPiPActive = true
        guard preparePiPIfNeeded() else {
            wantsPiPActive = false
            stopCapture()
            return "画中画没能启动：请确认系统设置里允许画中画，再试一次"
        }
        updatePiPAutomaticStartPolicy()
        updatePiPSourceGeometry()
        requestPiPStartWhenReady()
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
        autoHidePending = false
        pipHidden = false
        wantsPiPActive = false
        pipStartWorkItem?.cancel()
        pipStartWorkItem = nil
        defaults.set(false, forKey: Keys.active)
        defaults.removeObject(forKey: Keys.heartbeat)
        timer?.cancel()
        timer = nil
        updatePiPAutomaticStartPolicy()
        pipController?.stopPictureInPicture()
        resetMainWindowGeometryIfNeeded()
        stopCapture()
        silentPlayer?.stop()
        silentPlayer = nil
        if isRunning {
            isRunning = false
            statusText = "未开启"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - PiP（照全局高刷 GlobalRefresh-PiP 的实现搬，只去掉 120Hz 部分）

    /// 当前窗口尺寸：宽固定，隐藏时高 0.1，显示时是滑块的悬浮高度。
    private var currentPiPSize: CGSize {
        CGSize(width: pipWidth, height: pipHidden ? minPiPHeight : CGFloat(pipHeight))
    }

    /// 画中画专用窗口（备一次）：透明、盖在主窗口之上但不挡触摸
    /// （根视图关了交互，手点会穿过去）。源视图建在这个窗口里，
    /// 画中画动画只动这个窗口，主界面不受牵连。
    private func setupPiPWindow() {
        guard pipWindow == nil, let scene = pipHostView?.window?.windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        window.rootViewController = root
        window.isHidden = false
        pipWindow = window
        pipRootViewController = root
    }

    /// 源视图：建在画中画专用窗口里、居中、宽高约束跟窗口尺寸走、alpha 1。
    /// （之前用状态行里 8×8 几乎透明的小圆点当源视图，窗口没正常成形，
    /// 系统还把整个应用窗口当成画中画内容收走，界面出现双份渲染。）
    private func setupPiPSourceView() {
        setupPiPWindow()
        guard let host = pipRootViewController?.view, pipSourceView == nil else { return }
        let source = UIView()
        source.backgroundColor = .clear
        source.isOpaque = false
        source.isUserInteractionEnabled = false
        source.layer.cornerRadius = 18
        source.layer.cornerCurve = .continuous
        source.clipsToBounds = true
        source.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(source)
        let width = source.widthAnchor.constraint(equalToConstant: currentPiPSize.width)
        let height = source.heightAnchor.constraint(equalToConstant: currentPiPSize.height)
        NSLayoutConstraint.activate([
            source.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            source.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            width, height,
        ])
        pipSourceView = source
        pipSourceWidthConstraint = width
        pipSourceHeightConstraint = height
    }

    /// 内容：控制器视图透明，里面铺一张不透明的脸（深底＋盾牌＋「守护中」），
    /// 约束贴满四边——内容实打实铺满，系统才按 preferredContentSize 给窗口。
    private func setupPiPContent() {
        let contentController = AVPictureInPictureVideoCallViewController()
        contentController.preferredContentSize = currentPiPSize
        contentController.view.backgroundColor = .clear
        contentController.view.isOpaque = false
        contentController.view.layer.backgroundColor = UIColor.clear.cgColor
        contentController.view.layer.isOpaque = false
        contentController.view.clipsToBounds = true
        callViewController = contentController

        let content = UIView()
        content.backgroundColor = UIColor(white: 0.07, alpha: 1)
        content.isOpaque = true
        content.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "shield.lefthalf.filled"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "守护中"
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        contentController.view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentController.view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentController.view.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentController.view.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentController.view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        pipContentView = content
        contentController.view.layoutIfNeeded()
    }

    /// 备好整套画中画（源视图＋内容＋控制器），备过就复用。
    private func preparePiPIfNeeded() -> Bool {
        if pipController != nil { return true }
        guard pipHostView != nil else { return false }
        setupPiPSourceView()
        guard let source = pipSourceView else { return false }
        setupPiPContent()
        guard let contentController = callViewController else { return false }
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source,
            contentViewController: contentController
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        pipController = pip
        applyPiPControlsStyle()
        pip.requiresLinearPlayback = true
        updatePiPAutomaticStartPolicy()
        return true
    }

    private func applyPiPControlsStyle() {
        let style = 2
        pipController?.setValue(style, forKey: "controlsStyle")
    }

    private func updatePiPAutomaticStartPolicy() {
        pipController?.canStartPictureInPictureAutomaticallyFromInline = wantsPiPActive
    }

    /// 源视图几何跟窗口尺寸对齐（照全局高刷的 updatePiPSourceGeometry）。
    private func updatePiPSourceGeometry() {
        guard let source = pipSourceView else { return }
        if let width = pipSourceWidthConstraint, let height = pipSourceHeightConstraint {
            width.constant = currentPiPSize.width
            height.constant = currentPiPSize.height
        }
        source.alpha = 1
        source.layer.opacity = 1
        callViewController?.view.alpha = 1
        pipRootViewController?.view.layoutIfNeeded()
    }

    /// 保险：万一主窗口被画中画动画留下了位移/缩放，恢复原样。
    private func resetMainWindowGeometryIfNeeded() {
        guard let window = pipHostView?.window else { return }
        if window.transform != .identity {
            window.transform = .identity
        }
        if let rootView = window.rootViewController?.view, rootView.transform != .identity {
            rootView.transform = .identity
        }
    }

    /// 等画中画「可以启动」了再启动，还不行就隔一会儿再试（照全局高刷的
    /// WhenReady 做法），最多试 10 次。
    private func requestPiPStartWhenReady(attempt: Int = 0) {
        pipStartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.wantsPiPActive, !self.stopping,
                  let pip = self.pipController, !pip.isPictureInPictureActive else { return }
            guard pip.isPictureInPicturePossible else {
                if attempt < 10 {
                    self.requestPiPStartWhenReady(attempt: attempt + 1)
                } else {
                    self.log?("画中画暂时启动不了（系统说还不行），请再试一次", .warning)
                }
                return
            }
            pip.startPictureInPicture()
        }
        pipStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.25), execute: workItem)
    }

    /// 窗口尺寸一处同步：内容控制器 preferredContentSize＋源视图约束。
    private func applyPiPGeometry() {
        callViewController?.preferredContentSize = currentPiPSize
        updatePiPSourceGeometry()
    }

    /// 守护运行中把窗口压到 0.1（完全隐藏）或恢复成悬浮高度。
    func setPiPHidden(_ hidden: Bool) {
        pipHidden = hidden
        applyPiPGeometry()
        objectWillChange.send()
    }

    /// 滑块调悬浮高度：存下来，窗口正显示着就即时改尺寸。
    func setPiPHeight(_ height: Double) {
        pipHeight = height
        if isRunning && !pipHidden {
            applyPiPGeometry()
        }
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
            // 一键开启并隐藏：窗口已经显示出来了，停一下再自动压到 0.1。
            if self.autoHidePending {
                self.autoHidePending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard self.isRunning else { return }
                    self.setPiPHidden(true)
                    self.log?("画中画已自动隐藏（0.1）", .info)
                }
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.resetMainWindowGeometryIfNeeded()
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
