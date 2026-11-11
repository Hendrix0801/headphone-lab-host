import Cocoa
import CoreAudio

import Foundation

let appLogPath = "/tmp/hplab_app.log"
func appLog(_ msg: String) {
    let line = String(format: "%@ %@\n", ISO8601DateFormatter().string(from: Date()), msg)
    if let h = FileHandle(forWritingAtPath: appLogPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: appLogPath, contents: line.data(using: .utf8))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var main: AppDelegate?

    private let host = HostEngine.shared
    private let loopback = LoopbackAggregate.shared

    private var window: NSWindow!
    private var pluginContainer: NSView!
    private var sidebar: NSStackView!
    private var bufferPopup = NSPopUpButton()
    private var statusLabel = NSTextField(labelWithString: "")
    private var levelLabel = NSTextField(labelWithString: "输入电平：静音")
    private var routeLabel = NSTextField(labelWithString: "")
    private var loadingLabel = NSTextField(labelWithString: "正在加载 HEADPHONE LAB…")

    private var realOutputDeviceID: AudioDeviceID = 0
    private var levelTimer: Timer?

    private let bufferSizes: [UInt32] = [128, 256, 512, 1024]
    private let sidebarWidth: CGFloat = 250

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.main = self
        buildMainMenu()
        buildWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)

        startLevelTimer()
        beginLoad()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.installSignalHandler()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        performCleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func performCleanup() {
        host.savePluginState()
        let currentDefault = AudioDevices.defaultOutputDeviceID()
        if isOurVirtualDevice(currentDefault), realOutputDeviceID != 0 {
            AudioDevices.setDefaultOutputDevice(realOutputDeviceID)
        }
        // 还原真实设备的音量
        if savedRealVolume >= 0, realOutputDeviceID != 0 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var vol = savedRealVolume
            AudioObjectSetPropertyData(realOutputDeviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
        loopback.destroy()
        captureProcess?.terminate()
        captureProcess = nil
    }

    /// pkill / SIGTERM 不会走 applicationWillTerminate，用 信号→管道→GCD 兜底清理。
    private var sigtermPipe: [Int32] = [-1, -1]
    private var sigtermSource: DispatchSourceRead?

    private func installSignalHandler() {
        guard sigtermSource == nil else { return }
        pipe(&sigtermPipe)
        AppDelegate.sigtermPipeWrite = sigtermPipe[1]
        var handler: sigaction = sigaction()
        sigemptyset(&handler.sa_mask)
        handler.__sigaction_u.__sa_handler = AppDelegate.sigtermTrampoline
        sigaction(SIGTERM, &handler, nil)

        let source = DispatchSource.makeReadSource(fileDescriptor: sigtermPipe[0], queue: .main)
        source.setEventHandler { [weak self] in
            NSLog("[host] SIGTERM received, cleaning up")
            self?.performCleanup()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private static let sigtermTrampoline: @convention(c) (Int32) -> Void = { _ in
        var byte: UInt8 = 1
        if AppDelegate.sigtermPipeWrite >= 0 {
            _ = write(AppDelegate.sigtermPipeWrite, &byte, 1)
        }
    }

    private nonisolated(unsafe) static var sigtermPipeWrite: Int32 = -1

    // MARK: - Startup

    private func beginLoad() {
        statusLabel.stringValue = "正在加载插件…"
        host.instantiatePlugin { [weak self] error in
            guard let self else { return }
            if let error {
                self.showError(error.localizedDescription)
                return
            }
            NSLog("[host] plugin instantiated")
            self.host.restorePluginState()
            self.embedPluginView()

            self.loopback.cleanupStale()
            self.installDefaultOutputListener()
            self.updateRouting(reconfigure: false)
            self.reconfigureEngine()
        }
    }

    private func embedPluginView() {
        guard let rawUnit = host.rawUnit else { return }
        guard let view = PluginViewLoader.loadView(rawUnit: rawUnit, size: NSMakeSize(876, 704)) else {
            loadingLabel.stringValue = "插件界面加载失败，请重启应用重试"
            return
        }
        loadingLabel.isHidden = true
        view.frame = pluginContainer.bounds
        pluginContainer.addSubview(view)
        NSLog("[host] plugin view embedded: %.0fx%.0f", view.bounds.width, view.bounds.height)
        window.title = "HEADPHONE LAB"
    }

    // MARK: - Automatic routing (eqmac-style takeover)

    private func isOurVirtualDevice(_ id: AudioDeviceID) -> Bool {
        DriverSink.isDriverDevice(id)
            || AudioDevices.deviceUID(id) == LoopbackAggregate.aggregateUID
    }

    /// 虚拟/回环类设备的 UID 前缀：不能作为播放目标，也不从中接管。
    private func isVirtualOutputUID(_ uid: String) -> Bool {
        return uid.hasPrefix("OrayVirtualAudioDevice")
            || uid.hasPrefix("BlackHole")
            || uid.hasPrefix("EQM")
            || uid.hasPrefix("local.headphonelab")
    }

    private func isOtherVirtualDevice(_ id: AudioDeviceID) -> Bool {
        guard let uid = AudioDevices.deviceUID(id) else { return false }
        return isVirtualOutputUID(uid)
    }

    /// 选择真实的播放设备：优先沿用当前选择（仍在线时），否则取第一个物理输出。
    private func pickRealOutput() -> AudioDeviceID {
        let outputs = AudioDevices.outputDevices()
        if realOutputDeviceID != 0,
           let uid = AudioDevices.deviceUID(realOutputDeviceID),
           !isVirtualOutputUID(uid),
           outputs.contains(where: { $0.id == realOutputDeviceID }) {
            return realOutputDeviceID
        }
        return outputs.first {
            guard let uid = AudioDevices.deviceUID($0.id) else { return false }
            return !isVirtualOutputUID(uid)
        }?.id ?? 0
    }

    private func installDefaultOutputListener() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(system, &defaultAddr, AppDelegate.routingListener, nil)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(system, &devicesAddr, AppDelegate.routingListener, nil)
    }

    private static let routingListener: AudioObjectPropertyListenerProc = { _, _, _, _ in
        DispatchQueue.main.async {
            AppDelegate.main?.updateRouting()
        }
        return noErr
    }

    private func updateRouting(reconfigure: Bool = true) {
        // 驱动未加载：回退到聚合设备方案（BlackHole/Oray）。
        guard DriverSink.deviceID() != nil else {
            fallbackAggregateRouting(reconfigure: reconfigure)
            return
        }
        loopback.destroy()

        let currentDefault = AudioDevices.defaultOutputDeviceID()

        if DriverSink.isDriverDevice(currentDefault) {
            // 已接管。
            if realOutputDeviceID == 0 {
                realOutputDeviceID = DriverSink.resolveRealOutput()
            }
            updateRouteLabel()
            return
        }

        if isOtherVirtualDevice(currentDefault) {
            routeLabel.stringValue = "系统声音接入：\n系统输出当前是其他虚拟设备（eqMac 等），本 app 待命。\n\n若想使用本 app 处理，请退出 eqmac，或在系统菜单选择真实的扬声器/耳机。"
            return
        }

        // 真实设备 → 自动接管：改名 + 音量同步 + 设为系统输出。
        realOutputDeviceID = currentDefault
        let baseName = AudioDevices.info(currentDefault)?.name ?? "输出设备"
        let name = "\(baseName)\(DriverSink.nameSuffix)"
        if DriverSink.setName(name), let driverID = DriverSink.deviceID() {
            syncVolumeToDriver(from: currentDefault)
            AudioDevices.setDefaultOutputDevice(driverID)
        }
        if reconfigure { reconfigureEngine() }
        updateRouteLabel()
    }

    private var savedRealVolume: Float = -1

    /// 把真实设备的当前音量复制到驱动的音量控件，并将真实设备拉满，
    /// 使系统音量键（驱动控件）成为唯一音量级，保证切换时音量感知连续。
    private func syncVolumeToDriver(from realID: AudioDeviceID) {
        guard let driverID = DriverSink.deviceID() else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(realID, &addr, 0, nil, &size, &vol) == noErr else { return }
        savedRealVolume = vol
        setDriverVolumeScalar(vol)
        var full: Float32 = 1.0
        AudioObjectSetPropertyData(realID, &addr, 0, nil, size, &full)
    }

    private func setDriverVolumeScalar(_ v: Float32) {
        guard let driverID = DriverSink.deviceID() else { return }
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(driverID, &listAddr, 0, nil, &listSize) == noErr else { return }
        let count = Int(listSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return }
        var controls = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(driverID, &listAddr, 0, nil, &listSize, &controls) == noErr else { return }
        for control in controls {
            var classAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyClass,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cls = AudioClassID(0)
            var clsSize = UInt32(MemoryLayout<AudioClassID>.size)
            guard AudioObjectGetPropertyData(control, &classAddr, 0, nil, &clsSize, &cls) == noErr else { continue }
            guard cls == kAudioLevelControlClassID else { continue }
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioLevelControlPropertyScalarValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value = v
            AudioObjectSetPropertyData(control, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            return
        }
    }

    private func updateRouteLabel() {
        if DriverSink.isDriverDevice(AudioDevices.defaultOutputDeviceID()) {
            let name = DriverSink.currentName() ?? DriverSink.defaultDeviceName
            routeLabel.stringValue = "系统声音接入：\n已接管系统输出\n「\(name)」\n\n在系统菜单里选其他扬声器/耳机\n即可切换；退出 app 自动切回。"
        } else {
            routeLabel.stringValue = "系统声音接入：\n未接管。"
        }
    }

    private func fallbackAggregateRouting(reconfigure: Bool) {
        let currentDefault = AudioDevices.defaultOutputDeviceID()
        if AudioDevices.deviceUID(currentDefault) == LoopbackAggregate.aggregateUID {
            if loopback.realOutputDeviceID == 0 {
                _ = loopback.adoptOrRecreate()
            }
            if realOutputDeviceID == 0 { realOutputDeviceID = loopback.realOutputDeviceID }
            if reconfigure { reconfigureEngine() }
            let name = AudioDevices.info(loopback.deviceID)?.name ?? "Headphone Lab"
            routeLabel.stringValue = "系统声音接入：\n已接管系统输出「\(name)」\n\n（未安装音频驱动，正在使用回退方案；安装驱动可获得完整体验）"
            return
        }
        if isOtherVirtualDevice(currentDefault) {
            // 默认输出是某个虚拟设备（如拔插后系统落到 BlackHole）：
            // 保持既定真实目标（或重新挑选），并在尚未接管时完成接管。
        } else if AudioDevices.deviceUID(currentDefault) != LoopbackAggregate.aggregateUID {
            realOutputDeviceID = currentDefault
        }
        realOutputDeviceID = pickRealOutput()
        guard realOutputDeviceID != 0 else {
            routeLabel.stringValue = "系统声音接入：\n没有可用的真实输出设备。"
            return
        }
        let name = loopback.recreate(realOutput: realOutputDeviceID)
        if name != nil, loopback.deviceID != 0 {
            AudioDevices.setDefaultOutputDevice(loopback.deviceID)
        }
        if reconfigure { reconfigureEngine() }
        if let name {
            routeLabel.stringValue = "系统声音接入：\n将系统输出切换为「\(name)」\n\n（未安装音频驱动，正在使用回退方案）"
        } else if LoopbackAggregate.sinkDeviceID == 0 {
            routeLabel.stringValue = "系统声音接入：\n未安装音频驱动，也未检测到回环设备。\n参考：make install-driver-system"
        }
    }

    private var captureProcess: Process?
    private var lastEngineRetry = Date.distantPast
    private var lastCaptureTick: UInt64 = 0
    private var frozenTicks = 0
    private var lastHelperBounce = Date.distantPast

    /// 采集恢复：helper 模式重启助手；驱动模式仅重新映射 shm。
    private func bounceCapture() {
        if DriverSink.deviceID() != nil {
            host.shmReader = ShmCaptureReader()
            lastCaptureTick = 0
            frozenTicks = 0
            return
        }
        captureProcess?.terminate()
        captureProcess = nil
        host.shmReader = nil
        guard ensureCaptureRunning() else { return }
        var reader: ShmCaptureReader? = nil
        for _ in 0..<20 {
            reader = ShmCaptureReader()
            if reader != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let reader {
            host.shmReader = reader
            lastCaptureTick = 0
        }
    }

    /// 启动/复用采集助手进程（它持有 BlackHole 输入流并写入共享内存）。
    private func ensureCaptureRunning() -> Bool {
        let sink = LoopbackAggregate.sinkDeviceID
        guard sink != 0 else { return false }
        if let p = captureProcess, p.isRunning { return true }
        let p = Process()
        p.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/HeadphoneLabCapture")
        p.arguments = ["\(sink)"]
        do {
            try p.run()
            captureProcess = p
            return true
        } catch {
            NSLog("[host] capture helper launch failed: %@", error.localizedDescription)
            return false
        }
    }

    private var lastConfiguredOutput: AudioDeviceID = 0

    private func reconfigureEngine() {
        guard realOutputDeviceID != 0 else {
            updateStatus("等待选择输出设备")
            return
        }
        // 重配去抖：目标未变且引擎在跑时跳过（设备切换事件常连续触发多次）。
        if realOutputDeviceID == lastConfiguredOutput, host.isRunning {
            updateStatus()
            return
        }
        let driverMode = DriverSink.deviceID() != nil
        if driverMode {
            // 驱动模式：音频由驱动直接写入 shm，无需采集助手。
            if captureProcess != nil {
                captureProcess?.terminate()
                captureProcess = nil
            }
        } else {
            guard ensureCaptureRunning() else {
                updateStatus("无法启动采集助手")
                return
            }
        }
        var reader: ShmCaptureReader? = nil
        for _ in 0..<20 {
            reader = ShmCaptureReader()
            if reader != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let reader else {
            updateStatus(driverMode ? "驱动共享内存未就绪" : "采集共享内存未就绪")
            return
        }
        host.shmReader = reader
        do {
            host.recreateEngine()
            try host.setOutputDevice(realOutputDeviceID)
            NSLog("[host] rates: input=%.0fHz output=%.0fHz", host.inputSampleRate, host.outputSampleRate)
            try host.buildGraph()
            try host.start()
            host.reassertOutputDevice(realOutputDeviceID)
            lastConfiguredOutput = realOutputDeviceID
            NSLog("[host] engine running")
            updateStatus()
        } catch {
            appLog("engine setup failed: \(error.localizedDescription)")
            updateStatus(error.localizedDescription)
        }
    }

    // MARK: - UI construction

    private func buildWindow() {
        let contentSize = NSSize(width: 876 + sidebarWidth, height: 704)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "HEADPHONE LAB"
        window.contentMinSize = NSSize(width: 700 + sidebarWidth, height: 480)

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentView = content

        pluginContainer = NSView()
        pluginContainer.translatesAutoresizingMaskIntoConstraints = false
        pluginContainer.autoresizesSubviews = true
        content.addSubview(pluginContainer)

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.alignment = .center
        pluginContainer.addSubview(loadingLabel)

        sidebar = NSStackView(views: makeSidebarItems())
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 12
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        NSLayoutConstraint.activate([
            pluginContainer.topAnchor.constraint(equalTo: content.topAnchor),
            pluginContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pluginContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pluginContainer.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),

            loadingLabel.centerXAnchor.constraint(equalTo: pluginContainer.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: pluginContainer.centerYAnchor),

            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth - 32),
        ])
    }

    private func wrapLabel(_ label: NSTextField) {
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = sidebarWidth - 32
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func makeSidebarItems() -> [NSView] {
        wrapLabel(statusLabel)
        wrapLabel(levelLabel)

        let bufferLabel = NSTextField(labelWithString: "缓冲区大小")
        bufferLabel.font = NSFont.systemFont(ofSize: 11)
        bufferPopup.removeAllItems()
        bufferPopup.addItems(withTitles: bufferSizes.map { "\($0) 采样" })
        bufferPopup.selectItem(at: 1)
        bufferPopup.target = self
        bufferPopup.action = #selector(bufferSizeChanged(_:))

        wrapLabel(routeLabel)

        let volumeLabel = NSTextField(labelWithString: "输出音量")
        volumeLabel.font = NSFont.systemFont(ofSize: 11)
        let volumeSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        let routeHeading = NSTextField(labelWithString: "系统声音")
        routeHeading.font = NSFont.boldSystemFont(ofSize: 13)
        let takeoverButton = NSButton(title: "接管系统输出", target: self, action: #selector(takeoverRequested))

        return [
            statusLabel,
            levelLabel,
            volumeLabel, volumeSlider,
            bufferLabel, bufferPopup,
            routeHeading,
            routeLabel,
            takeoverButton,
        ]
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 HEADPHONE LAB", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 HEADPHONE LAB", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func bufferSizeChanged(_ sender: NSPopUpButton) {
        let frames = bufferSizes[sender.indexOfSelectedItem]
        if realOutputDeviceID != 0 {
            AudioDevices.setBufferFrameSize(realOutputDeviceID, frames)
        }
        if let driverID = DriverSink.deviceID() {
            AudioDevices.setBufferFrameSize(driverID, frames)
        }
        do {
            try host.restart()
            updateStatus()
        } catch {
            updateStatus(error.localizedDescription)
        }
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        host.outputVolume = sender.floatValue
    }

    /// 合盖睡眠后音频链路各环（引擎/驱动/设备枚举）都可能失效，醒来强制重建。
    @objc private func systemDidWake() {
        appLog("system woke, reconfiguring")
        lastConfiguredOutput = 0
        host.shmReader = nil
        updateRouting(reconfigure: false)
        reconfigureEngine()
    }

    @objc private func takeoverRequested() {
        // 强制重新评估：把系统输出切到真实设备再接管。
        if realOutputDeviceID != 0 {
            AudioDevices.setDefaultOutputDevice(realOutputDeviceID)
        }
        updateRouting()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "HEADPHONE LAB 独立宿主"
        alert.informativeText = "以独立应用方式运行 beyerdynamic HEADPHONE LAB (AU) v1.1.0\n选择扬声器/耳机后自动接管系统输出，无需手动配置。"
        alert.runModal()
    }

    // MARK: - Helpers

    private func startLevelTimer() {
        var tick = 0
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            // 周期统计：定位偶发无声的取证数据。
            if tick % 60 == 0, let reader = self.host.shmReader {
                appLog(String(format: "stats w=%llu r=%llu avail=%d rate=%.0f tick=%llu engine=%d",
                    reader.debugWritePos, reader.debugReadPos, reader.availableFrames,
                    reader.sampleRate, reader.currentTick, self.host.isRunning ? 1 : 0))
            }
            // 采集看门狗：心跳冻结说明采集侧停摆，自动恢复。
            if let reader = self.host.shmReader {
                let t = reader.currentTick
                if t == self.lastCaptureTick {
                    self.frozenTicks += 1
                } else {
                    self.frozenTicks = 0
                    self.lastCaptureTick = t
                }
                if !self.host.isRunning {
                    // 设备插拔瞬间音频会话会混乱（-10851 等），
                    // 带间隔重试，避免风暴，也给会话恢复的时间。
                    if Date().timeIntervalSince(self.lastEngineRetry) > 2.0 {
                        self.lastEngineRetry = Date()
                        appLog("engine not running, reconfiguring")
                        self.lastConfiguredOutput = 0
                        self.reconfigureEngine()
                    }
                }
                if self.frozenTicks >= 8, Date().timeIntervalSince(self.lastHelperBounce) > 10 {
                    self.lastHelperBounce = Date()
                    self.frozenTicks = 0
                    appLog("capture stalled, recovering")
                    self.bounceCapture()
                }
                // 静音自动挂起：长时间无输入音频时暂停引擎，
                // 释放 coreaudiod 的防睡眠断言，让系统可以正常休眠。
                if self.frozenTicks >= 16, self.host.isRunning {
                    appLog("no input for 8s, suspending engine")
                    self.host.stop()
                    self.updateStatus("已挂起（无音频输入）")
                }
                if self.frozenTicks == 0, !self.host.isRunning, self.lastConfiguredOutput != 0 {
                    appLog("input resumed, restarting engine")
                    self.reconfigureEngine()
                }
            }
            let level = self.host.consumeInputLevel()
            let peak = self.host.debugPeak
            self.host.debugPeak = 0
            if level > 0.00003 {
                let db = 20 * log10(level)
                self.levelLabel.stringValue = String(format: "输入电平：%.1f dB", db)
            } else {
                self.levelLabel.stringValue = "输入电平：静音"
            }
            if tick % 4 == 0, level > 0.00003 {
                NSLog("[host] meter rms=%.6f peak=%.4f", level, peak)
            }
        }
    }

    private func updateStatus(_ message: String? = nil) {
        if let message {
            statusLabel.stringValue = message
            return
        }
        statusLabel.stringValue = host.isRunning ? "引擎运行中" : "已停止"
    }

    private func showError(_ message: String) {
        updateStatus(message)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
