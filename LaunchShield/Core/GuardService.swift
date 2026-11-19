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
/// 画中画源视图的宿主控制器（GPT 方案，2026-11-17）：只承载源视图，
/// 不含任何应用界面。源视图挂在它自己的独立窗口里，主界面零接触。
@MainActor
private final class PiPSourceHostViewController: UIViewController {
    override func loadView() {
        let hostView = UIView()
        hostView.backgroundColor = .clear
        hostView.isOpaque = false
        hostView.isUserInteractionEnabled = false
        hostView.clipsToBounds = false
        view = hostView
    }

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

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
            return min(max(stored, 0.1), 240)
        }
        set {
            defaults.set(min(max(newValue, 0.1), 240), forKey: Keys.pipHeight)
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
    private var pipController: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    /// 画中画独立宿主窗口与宿主控制器（GPT 方案）：源视图只住在这里。
    private var pipHostWindow: UIWindow?
    private var pipHostViewController: PiPSourceHostViewController?
    private var pipSourceView: UIView?
    private var pipSourceWidthConstraint: NSLayoutConstraint?
    private var pipSourceHeightConstraint: NSLayoutConstraint?
    private var pipContentView: UIView?
    private var wantsPiPActive = false
    private var pipStartWorkItem: DispatchWorkItem?
    /// 隐藏时窗口压到的高度。
    private let minPiPHeight: CGFloat = 0.1
    private let pipWidth: CGFloat = 300
    /// 源视图固定尺寸，永远不跟着画中画高度变（GPT 方案的核心之一）：
    /// 它是系统计算进出动画的锚点，锚点一动，动画的恢复定位就乱。
    private let pipSourceSize = CGSize(width: 300, height: 169)
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var stopping = false
    private var silentPlayer: AVAudioPlayer?

    /// 启动时发现上次守护还开着（进程是被杀掉/装新版断的，不是手动关的）：
    /// AppState 在通道就绪后据此自动把守护续上。
    private(set) var wasActiveAtLaunch = false

    override init() {
        super.init()
        // A session marked active at launch was killed while it was running.
        if defaults.bool(forKey: Keys.active) {
            wasActiveAtLaunch = true
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

    /// 应用自己的主窗口（从场景里现找；排除画中画的宿主窗口）。
    private func appKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
        guard let scene else { return nil }
        return scene.windows.first { $0.isKeyWindow && $0 !== pipHostWindow }
            ?? scene.windows.first { !$0.isHidden && $0 !== pipHostWindow }
    }

    /// Returns nil when PiP was asked to start, or a Chinese reason.
    /// 守护开启时画中画窗口先按悬浮高度显示出来；`hidden`（一键开启并隐藏）
    /// 是在窗口显示出来、启动成功之后，再自动压到 0.1 藏起来。
    func start(hidden: Bool = false) -> String? {
        if isRunning { return nil }
        guard appKeyWindow() != nil else {
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
        wantsPiPActive = true
        guard preparePiPIfNeeded() else {
            wantsPiPActive = false
            cleanupPiPResources()
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
        if let pip = pipController, pip.isPictureInPictureActive {
            // 还在播就只发停止请求，资源等 DidStop 回调里再拆，
            // 免得系统退出动画还没做完源视图先没了。
            pip.stopPictureInPicture()
        } else {
            cleanupPiPResources()
        }
        silentPlayer?.stop()
        silentPlayer = nil
        if isRunning {
            isRunning = false
            statusText = "未开启"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - PiP（GPT 方案，2026-11-17：独立宿主窗口＋源视图固定尺寸＋无私有 KVC＋停后整套拆）

    /// 当前窗口尺寸：宽固定，隐藏时高 0.1，显示时是滑块的悬浮高度。
    private var currentPiPSize: CGSize {
        CGSize(width: pipWidth, height: pipHidden ? minPiPHeight : CGFloat(pipHeight))
    }

    /// 画中画独立宿主窗口：透明、盖在主窗口之上但整个窗口关交互
    /// （点按穿透）、从不抢 key window。源视图只住在这里，主界面零接触。
    private func setupPiPHostWindow() -> Bool {
        if pipHostWindow != nil { return true }
        guard let mainWindow = appKeyWindow(), let scene = mainWindow.windowScene else { return false }
        let hostController = PiPSourceHostViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isUserInteractionEnabled = false
        window.rootViewController = hostController
        hostController.loadViewIfNeeded()
        hostController.view.backgroundColor = .clear
        hostController.view.isOpaque = false
        hostController.view.isUserInteractionEnabled = false
        pipHostViewController = hostController
        pipHostWindow = window
        window.isHidden = false
        return true
    }

    /// 源视图：建在宿主窗口里、居中、固定 300×169，永远不改尺寸。
    private func setupPiPSourceView() {
        guard pipSourceView == nil, setupPiPHostWindow(),
              let host = pipHostViewController?.view else { return }
        let source = UIView()
        source.backgroundColor = .clear
        source.isOpaque = false
        source.isUserInteractionEnabled = false
        source.layer.cornerRadius = 18
        source.layer.cornerCurve = .continuous
        source.clipsToBounds = true
        source.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(source)
        let width = source.widthAnchor.constraint(equalToConstant: pipSourceSize.width)
        let height = source.heightAnchor.constraint(equalToConstant: pipSourceSize.height)
        NSLayoutConstraint.activate([
            source.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            source.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            width, height,
        ])
        pipSourceView = source
        pipSourceWidthConstraint = width
        pipSourceHeightConstraint = height
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }

    /// 内容：控制器视图透明，里面铺一张不透明的脸（深底＋盾牌＋「守护中」），
    /// 约束贴满四边——内容实打实铺满，系统才按 preferredContentSize 给窗口。
    private func setupPiPContent() {
        let contentController = AVPictureInPictureVideoCallViewController()
        contentController.preferredContentSize = currentPiPSize
        contentController.view.backgroundColor = .clear
        contentController.view.isOpaque = false
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
        contentController.view.setNeedsLayout()
        contentController.view.layoutIfNeeded()
    }

    /// 备好整套画中画（宿主窗口＋源视图＋内容＋控制器），备过就复用。
    /// 不再设置 controlsStyle 私有 KVC（GPT 点名的主要嫌疑：所有出事
    /// 版本都保留着它，它不是公开接口）。
    private func preparePiPIfNeeded() -> Bool {
        if pipController != nil { return true }
        guard appKeyWindow() != nil else { return false }
        guard setupPiPHostWindow() else { return false }
        setupPiPSourceView()
        guard let source = pipSourceView else {
            cleanupPiPResources()
            return false
        }
        setupPiPContent()
        guard let contentController = callViewController else {
            cleanupPiPResources()
            return false
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source,
            contentViewController: contentController
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        pipController = pip
        pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = wantsPiPActive
        return true
    }

    private func updatePiPAutomaticStartPolicy() {
        pipController?.canStartPictureInPictureAutomaticallyFromInline = wantsPiPActive
    }

    /// 整套拆掉画中画资源（控制器、内容、源视图、宿主窗口）。
    /// 只能在画中画已确认停止或启动失败后调用；下次开启重新备一套。
    private func cleanupPiPResources() {
        guard pipController?.isPictureInPictureActive != true else { return }
        pipController?.delegate = nil
        pipController = nil
        callViewController = nil
        pipContentView = nil
        pipSourceView?.removeFromSuperview()
        pipSourceView = nil
        pipSourceWidthConstraint = nil
        pipSourceHeightConstraint = nil
        if let window = pipHostWindow {
            window.isHidden = true
            window.rootViewController = nil
        }
        pipHostWindow = nil
        pipHostViewController = nil
    }

    /// 源视图尺寸固定，这里只保证它可见并触发布局，不动它的约束。
    private func updatePiPSourceGeometry() {
        guard let source = pipSourceView else { return }
        source.alpha = 1
        source.layer.opacity = 1
        source.setNeedsLayout()
        source.superview?.layoutIfNeeded()
        callViewController?.view.alpha = 1
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

    /// 画中画高度只由内容控制器的 preferredContentSize 管，
    /// 源视图尺寸固定不动。
    private func applyPiPGeometry() {
        guard let controller = callViewController else { return }
        controller.preferredContentSize = currentPiPSize
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
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

    /// 滑块显示的高度＝窗口现在的实际高度：藏着就是 0.1，露着就是悬浮高度。
    /// 一键开启并隐藏把窗口压到 0.1 时，滑块要跟着滑到最底，所以滑块
    /// 读的是这个值，不是单独存的悬浮高度。
    var pipDisplayHeight: Double {
        pipHidden ? Double(minPiPHeight) : pipHeight
    }

    /// 拖滑块：拖到最底（≤0.15）就是把窗口藏起来（悬浮高度还记着，
    /// 往回拖就恢复）；拖离最底就是设定悬浮高度，藏着的话顺手露出来。
    func setPipDisplayHeight(_ value: Double) {
        if value <= 0.15 {
            if !pipHidden {
                pipHidden = true
                if isRunning { applyPiPGeometry() }
                objectWillChange.send()
            }
        } else {
            pipHeight = value
            if pipHidden {
                pipHidden = false
                if isRunning { applyPiPGeometry() }
                objectWillChange.send()
            } else if isRunning {
                applyPiPGeometry()
            }
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
            // 视频通话式画中画的启动要靠 playAndRecord 这一档，但模式必须用
            // 普通模式，也不许开麦克风采集：videoChat 模式＋麦克风一开，
            // 系统就按「通话中」抢走全机声音路线，别家 App 的声音被赶去
            // 听筒、底部扬声器没声（2026-11-19 用户日志实证，关守护即恢复）。
            // 同理不带 allowBluetooth，免得蓝牙耳机被拉去走通话音质。
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log?("设置音频会话失败：\(error.localizedDescription)", .warning)
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
            // 启动回调迟到而用户已经关了守护：立刻停掉，不让它复活。
            if self.stopping || !self.wantsPiPActive {
                pictureInPictureController.stopPictureInPicture()
                return
            }
            self.isRunning = true
            self.statusText = "守护中"
            self.log?("画中画已启动，守护在后台继续", .success)
            // 一键开启并隐藏：窗口已经显示出来了，停一下再自动压到 0.1。
            if self.autoHidePending {
                self.autoHidePending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard self.isRunning, self.wantsPiPActive else { return }
                    self.setPiPHidden(true)
                    self.log?("画中画已自动隐藏（0.1）", .info)
                }
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            // 系统已确认停了，现在拆资源是安全的。
            self.cleanupPiPResources()
            guard self.isRunning else {
                self.stopping = false
                return
            }
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
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.statusText = "没启动"
            self.pipStartWorkItem?.cancel()
            self.pipStartWorkItem = nil
            self.wantsPiPActive = false
            self.cleanupPiPResources()
            self.defaults.set(false, forKey: Keys.active)
            self.timer?.cancel()
            self.timer = nil
            self.log?("画中画启动失败：\(error.localizedDescription)", .warning)
        }
    }
}
