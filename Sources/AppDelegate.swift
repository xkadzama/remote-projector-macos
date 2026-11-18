// Главное окно: подключение к проектору, экран, панель пульта.

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private let adb = ADB()
    private var scrcpy: ScrcpyClient!
    private var screenView: ScreenView!
    private var statusLabel: NSTextField!
    private var connectButton: NSButton!
    private var disconnectButton: NSButton!
    private var vpnButton: NSButton!
    private var powerButton: NSButton!
    private var modeSegment: NSSegmentedControl!
    private var screenContainer: ScreenContainer!
    private var qualityPopup: NSPopUpButton!
    private var hostField: NSTextField!
    private var deviceSize = CGSize(width: 1280, height: 720)
    /// Опорная точка для перевода движения мыши в стрелки.
    private var focusAnchor = (x: 640, y: 360)

    func applicationDidFinishLaunching(_ notification: Notification) {
        scrcpy = ScrcpyClient(adb: adb)
        buildMenu()
        buildWindow()
        wireVideo()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        scrcpy.stop()
        adb.disconnect()
    }

    // ---------------------------------------------------------------- меню

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О приложении «Проектор»",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Завершить", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let connItem = NSMenuItem()
        let connMenu = NSMenu()
        connMenu.addItem(withTitle: "Подключиться", action: #selector(connectAction), keyEquivalent: "k")
        connMenu.addItem(withTitle: "Отключиться", action: #selector(disconnectAction), keyEquivalent: "d")
        connMenu.addItem(.separator())
        connMenu.addItem(withTitle: "Снимок экрана", action: #selector(snapshotAction), keyEquivalent: "s")
        connItem.submenu = connMenu
        main.addItem(connItem)

        NSApp.mainMenu = main
    }

    // ---------------------------------------------------------------- окно

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Проектор"
        window.center()
        window.minSize = NSSize(width: 760, height: 520)
        // Заголовок прозрачный: содержимое уходит под него, как в Finder и QuickTime.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Style.windowBackground
        window.isMovableByWindowBackground = false

        let content = NSView()
        window.contentView = content

        // --- панель управления: вибро-подложка, сливается с заголовком окна
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .headerView
        bar.blendingMode = .behindWindow
        bar.state = .active
        content.addSubview(bar)

        // Поле пустое: адрес у каждого свой. Пример в подсказке, а ADB.host задаёт
        // то, что подставится, если ничего не вводить.
        hostField = NSTextField(string: "")
        hostField.translatesAutoresizingMaskIntoConstraints = false
        hostField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hostField.placeholderString = "192.168.1.50"
        hostField.toolTip = "IP-адрес проектора в вашей сети"
        bar.addSubview(hostField)

        // Главное действие — акцентное, как кнопка по умолчанию в диалогах macOS.
        connectButton = makeAccentButton(title: "Подключиться", target: self, action: #selector(connectAction))
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(connectButton)

        // Кнопка полного разрыва связи. Всегда на виду: это главный способ
        // убедиться, что удалённый доступ к проектору действительно закрыт.
        disconnectButton = NSButton(title: "Отключиться", target: self, action: #selector(disconnectAction))
        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.bezelStyle = .rounded
        disconnectButton.keyEquivalent = "d"
        disconnectButton.keyEquivalentModifierMask = .command
        disconnectButton.toolTip = "Разорвать связь с проектором: видео, управление и ADB"
        disconnectButton.isEnabled = false
        bar.addSubview(disconnectButton)

        statusLabel = makeStatusLabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLabel)

        qualityPopup = NSPopUpButton()
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false
        qualityPopup.addItems(withTitles: ["360p", "480p", "720p"])
        qualityPopup.selectItem(at: 0)
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)
        qualityPopup.toolTip = "Качество картинки с проектора"
        qualityPopup.controlSize = .small
        qualityPopup.font = .systemFont(ofSize: 11)
        bar.addSubview(qualityPopup)

        // VPN: иконка щита, зелёная при активном соединении.
        vpnButton = makeToolbarButton(symbol: "lock.shield", tooltip: "Включить или выключить VPN на проекторе",
                                      target: self, action: #selector(vpnAction))
        vpnButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(vpnButton)

        // Режим мыши — сегментированный переключатель, как в системных настройках.
        modeSegment = NSSegmentedControl(labels: ["Пульт", "Касание"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        modeSegment.selectedSegment = 0
        modeSegment.controlSize = .small
        modeSegment.font = .systemFont(ofSize: 11)
        modeSegment.toolTip = "Пульт: мышь двигает фокус стрелками. Касание: мышь кликает по экрану (в приложениях, не на главном экране)."
        bar.addSubview(modeSegment)

        powerButton = makeToolbarButton(symbol: "ellipsis.circle", tooltip: "Меню проектора",
                                        target: self, action: #selector(powerAction))
        powerButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(powerButton)

        // --- экран: скруглённая подложка, кадр внутри
        screenContainer = ScreenContainer()
        screenContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(screenContainer)

        screenView = ScreenView()
        screenView.translatesAutoresizingMaskIntoConstraints = false
        screenView.screenSize = deviceSize
        screenContainer.addSubview(screenView)

        // --- пульт: ряд равных кнопок внизу
        let remote: [(String, String, Selector)] = [
            ("chevron.left", "Влево", #selector(dpadLeft)),
            ("chevron.up", "Вверх", #selector(dpadUp)),
            ("circle.fill", "Выбрать", #selector(dpadCenter)),
            ("chevron.down", "Вниз", #selector(dpadDown)),
            ("chevron.right", "Вправо", #selector(dpadRight)),
            ("arrow.uturn.backward", "Назад", #selector(backAction)),
            ("house", "Домой", #selector(homeAction)),
            ("line.3.horizontal", "Меню", #selector(menuAction)),
        ]
        var padButtons: [NSButton] = []
        for (symbol, tip, sel) in remote {
            let b = makeRemoteButton(symbol: symbol, tooltip: tip, target: self, action: sel)
            b.translatesAutoresizingMaskIntoConstraints = false
            padButtons.append(b)
        }
        let pad = NSStackView(views: padButtons)
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.orientation = .horizontal
        pad.distribution = .fillEqually
        pad.spacing = Style.Metric.tight
        content.addSubview(pad)

        // Раскладка: панель сверху, экран растягивается, пульт снизу.
        // Отступ слева 78 — место под кнопки закрыть/свернуть/развернуть.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),

            hostField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 78),
            hostField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hostField.widthAnchor.constraint(equalToConstant: 132),

            connectButton.leadingAnchor.constraint(equalTo: hostField.trailingAnchor, constant: Style.Metric.gap),
            connectButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            disconnectButton.leadingAnchor.constraint(equalTo: connectButton.trailingAnchor, constant: Style.Metric.tight),
            disconnectButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: disconnectButton.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            // Правый край: меню, режим, VPN, качество — от края внутрь.
            powerButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Style.Metric.pad),
            powerButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            modeSegment.trailingAnchor.constraint(equalTo: powerButton.leadingAnchor, constant: -Style.Metric.gap),
            modeSegment.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            vpnButton.trailingAnchor.constraint(equalTo: modeSegment.leadingAnchor, constant: -Style.Metric.gap),
            vpnButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            qualityPopup.trailingAnchor.constraint(equalTo: vpnButton.leadingAnchor, constant: -Style.Metric.gap),
            qualityPopup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: qualityPopup.leadingAnchor, constant: -10),

            screenContainer.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            screenContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Style.Metric.pad),
            screenContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Style.Metric.pad),

            screenView.topAnchor.constraint(equalTo: screenContainer.topAnchor, constant: 1),
            screenView.leadingAnchor.constraint(equalTo: screenContainer.leadingAnchor, constant: 1),
            screenView.trailingAnchor.constraint(equalTo: screenContainer.trailingAnchor, constant: -1),
            screenView.bottomAnchor.constraint(equalTo: screenContainer.bottomAnchor, constant: -1),

            pad.topAnchor.constraint(equalTo: screenContainer.bottomAnchor, constant: 12),
            pad.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Style.Metric.pad),
            pad.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Style.Metric.pad),
            pad.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Style.Metric.pad),
            pad.heightAnchor.constraint(equalToConstant: Style.Metric.remoteHeight),
        ])

        wireInput()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(screenView)

        // Сразу подключаемся: обычно проектор уже в сети, и лишний клик ни к чему.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.connectAction()
        }
    }

    // ---------------------------------------------------------------- ввод

    private func wireInput() {
        // Тап: короткое касание.
        screenView.onTap = { [weak self] x, y in
            self?.scrcpy.touch(action: .down, x: x, y: y)
            self?.scrcpy.touch(action: .up, x: x, y: y)
        }

        // Перетаскивание: DOWN, затем MOVE, затем UP — так работает свайп на Android.
        var lastPoint: (Int, Int)?
        screenView.onDrag = { [weak self] phase, x, y in
            guard let self else { return }
            switch phase {
            case .begin:
                self.scrcpy.touch(action: .down, x: x, y: y)
                lastPoint = (x, y)
            case .move:
                // Слишком частые MOVE перегрузят канал — шлём не чаще, чем через 3 пикселя.
                if let last = lastPoint, abs(last.0 - x) < 3, abs(last.1 - y) < 3 { return }
                self.scrcpy.touch(action: .move, x: x, y: y)
                lastPoint = (x, y)
            case .end:
                self.scrcpy.touch(action: .up, x: x, y: y)
                lastPoint = nil
            }
        }

        screenView.onKey = { [weak self] name in
            guard let self, let code = ScrcpyClient.keyCode(named: name) else { return }
            self.scrcpy.press(code)
        }
        screenView.onText = { [weak self] text in
            guard let self else { return }
            // Инъекция символов в scrcpy понимает только латиницу и цифры.
            // Кириллицу Android через неё не принимает — предупреждаем, чтобы
            // не казалось, что ввод «сломался».
            let hasCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            if hasCyrillic {
                self.setStatus("кириллица не поддерживается каналом scrcpy — используйте экранную клавиатуру проектора",
                               color: .systemOrange)
            }
            self.scrcpy.text(text)
        }
        // Режим пульта: движение мыши превращается в стрелки.
        // Главный экран Android TV не принимает касания — фокус двигается только
        // стрелками, поэтому «наведи и щёлкни» здесь реализуется через dpad.
        screenView.onMove = { [weak self] x, y in
            guard let self else { return }
            self.moveFocus(x: x, y: y)
        }
        screenView.onTapAt = { [weak self] _, _ in
            self?.scrcpy.press(23)   // KEYCODE_DPAD_CENTER
        }

        screenView.onScroll = { [weak self] dx, dy in
            guard let self else { return }
            self.scrcpy.scroll(x: 640, y: 360, dx: dx, dy: dy)
        }
    }

    // ---------------------------------------------------------------- видео

    private func wireVideo() {
        scrcpy.onFrame = { [weak self] image in
            guard let self else { return }
            self.screenView.image = image
            self.screenView.needsLayout = true
            self.screenView.needsDisplay = true
        }
        scrcpy.onFirstFrame = { [weak self] in
            guard let self else { return }
            // Диагностика канала управления: включается переменной окружения,
            // чтобы можно было проверить ввод без ручного клика по окну.
            // Проверка ввода текста: тап по полю и набор строки.
            if let text = ProcessInfo.processInfo.environment["PROYEKTOR_TYPE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dlog("проверка текста: тап по полю")
                    self.screenView.dpadMode = false
                    self.scrcpy.touch(action: .down, x: 640, y: 220)
                    self.scrcpy.touch(action: .up, x: 640, y: 220)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dlog("проверка текста: набор '\(text)'")
                        self.scrcpy.text(text)
                    }
                }
            }
            // Проверка кнопки «Отключиться»: через N секунд вызываем тот же
            // обработчик, что нажимает кнопка, и смотрим, закрылся ли доступ.
            if let delayText = ProcessInfo.processInfo.environment["PROYEKTOR_DISCONNECT_AFTER"],
               let delay = Double(delayText) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    dlog("самопроверка: нажимаю «Отключиться»")
                    self.disconnectAction()
                    // И сразу проверяем обратный путь: связь должна восстанавливаться.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        dlog("самопроверка: нажимаю «Подключиться» снова")
                        self.connectAction()
                    }
                }
            }
            if ProcessInfo.processInfo.environment["PROYEKTOR_SELFTEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dlog("selftest: клавиша ВНИЗ")
                    self.scrcpy.press(20)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dlog("selftest: тап в центр")
                        self.scrcpy.touch(action: .down, x: 640, y: 360)
                        self.scrcpy.touch(action: .up, x: 640, y: 360)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dlog("selftest: клавиша ВВЕРХ")
                            self.scrcpy.press(19)
                        }
                    }
                }
            }
            let size = self.scrcpy.screenSize
            self.deviceSize = CGSize(width: size.w, height: size.h)
            self.screenView.screenSize = self.deviceSize
            self.focusAnchor = (size.w / 2, size.h / 2)
        }
        scrcpy.onStop = { [weak self] reason in
            guard let self else { return }
            self.setStatus("видео: \(reason)", color: .systemOrange)
        }
    }

    private func setStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    // ---------------------------------------------------------------- действия

    @objc private func connectAction() {
        // Пустое поле — берём адрес по умолчанию, иначе подключение ушло бы в ""
        // и падало с невнятной ошибкой.
        let typed = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { adb.host = typed }
        setStatus("подключаюсь…")
        connectButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.adb.connect()
            DispatchQueue.main.async {
                self.connectButton.isEnabled = true
                if let error {
                    self.setStatus("ошибка: \(error)", color: .systemRed)
                    return
                }
                let size = self.adb.screenSize()
                self.deviceSize = CGSize(width: size.w, height: size.h)
                self.screenView.screenSize = self.deviceSize
                let name = self.adb.deviceName()
                self.window.title = "Проектор"
                self.window.subtitle = "\(name) · \(size.w)×\(size.h)"
                self.setStatus("подключено: \(name)", color: .systemGreen)
                self.refreshVPNState()
                self.scrcpy.start()
                self.connectButton.title = "Переподключиться"
                self.disconnectButton.isEnabled = true
            }
        }
    }

    /// Полный разрыв связи с проектором.
    ///
    /// Порядок важен: сначала останавливаем видео и каналы управления, потом
    /// просим сервер на проекторе завершиться, и только затем рвём сам ADB.
    /// Если делать в обратном порядке, сервер scrcpy останется висеть на
    /// устройстве и продолжит кодировать экран — то есть «отключился» было бы
    /// неправдой.
    @objc private func disconnectAction() {
        setStatus("отключаюсь…", color: .systemOrange)
        disconnectButton.isEnabled = false
        connectButton.isEnabled = false

        // Обрыв может занимать секунды: adb отвечает не мгновенно.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // scrcpy.stop() сам убивает сервер на проекторе и снимает проброс порта.
            self.scrcpy.stop()
            self.adb.disconnect()

            DispatchQueue.main.async {
                self.screenView.image = nil
                self.screenView.needsDisplay = true
                self.deviceSize = CGSize(width: 1280, height: 720)
                self.screenView.screenSize = self.deviceSize
                self.setStatus("отключено — доступа к проектору нет", color: .secondaryLabelColor)
                self.connectButton.title = "Подключиться"
                self.connectButton.isEnabled = true
                self.window.subtitle = ""
                self.setVPNIcon(up: false)
                self.vpnButton.contentTintColor = nil
            }
        }
    }

    @objc private func qualityChanged() {
        // Разрешение потока задаётся при запуске сервера, поэтому перезапускаем его.
        guard adb.isConnected else { return }
        let idx = qualityPopup.indexOfSelectedItem
        scrcpy.maxSize = idx == 0 ? 854 : (idx == 1 ? 1024 : 1280)
        scrcpy.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.adb.isConnected else { return }
            self.scrcpy.start()
        }
    }

    @objc private func vpnAction() {
        guard adb.isConnected else { return }
        let up = adb.vpnIsUp()
        let link = up ? "happ://disconnect" : "happ://connect"
        adb.run(["shell", "am start -a android.intent.action.VIEW -d '\(link)'"])
        setStatus(up ? "VPN выключаю…" : "VPN включаю…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.refreshVPNState()
        }
    }

    private func refreshVPNState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let up = self.adb.vpnIsUp()
            DispatchQueue.main.async { self.setVPNIcon(up: up) }
        }
    }

    /// Состояние VPN показываем иконкой: закрытый щит — выключен,
    /// закрашенный зелёный — включён. Текст уходит в подсказку, как в панелях macOS.
    private func setVPNIcon(up: Bool) {
        let name = up ? "lock.shield.fill" : "lock.shield"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        vpnButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "VPN")?
            .withSymbolConfiguration(config)
        vpnButton.contentTintColor = up ? .systemGreen : .secondaryLabelColor
        vpnButton.toolTip = up ? "VPN включён — нажмите, чтобы выключить"
                               : "VPN выключен — нажмите, чтобы включить"
    }

    @objc private func powerAction() {
        guard adb.isConnected else { return }
        adb.key("KEYCODE_MENU")
    }

    @objc private func snapshotAction() {
        guard let image = screenView.image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "проектор-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    // ---------------------------------------------------------------- пульт

    /// Переключение между «мышь как пульт» и «мышь как касание».
    ///
    /// Главный экран Android TV принимает только стрелки, а обычные приложения
    /// (браузер, YouTube, плееры) понимают касания. Поэтому режим переключаемый.
    @objc private func modeChanged() {
        let dpad = modeSegment.selectedSegment == 0
        screenView.dpadMode = dpad
        if dpad {
            focusAnchor = (Int(deviceSize.width) / 2, Int(deviceSize.height) / 2)
        }
        setStatus(dpad ? "режим пульта: мышь двигает фокус" : "режим касания: мышь кликает по экрану")
    }

    /// Двигает фокус в сторону курсора.
    ///
    /// Android TV не отдаёт позицию фокуса, поэтому действуем по накопленному
    /// смещению: как только курсор ушёл от опорной точки дальше порога, жмём
    /// стрелку в преобладающем направлении и запоминаем новую точку. Так мышь
    /// ведёт себя как пульт, не заваливая канал десятками нажатий.
    private func moveFocus(x: Int, y: Int) {
        let threshold = 40
        let dx = x - focusAnchor.x
        let dy = y - focusAnchor.y
        if abs(dx) < threshold && abs(dy) < threshold { return }
        if abs(dx) > abs(dy) {
            scrcpy.press(dx > 0 ? 22 : 21)      // вправо / влево
        } else {
            scrcpy.press(dy > 0 ? 20 : 19)      // вниз / вверх
        }
        focusAnchor = (x, y)
    }

    @objc private func dpadUp() { adb.key("KEYCODE_DPAD_UP") }
    @objc private func dpadDown() { adb.key("KEYCODE_DPAD_DOWN") }
    @objc private func dpadLeft() { adb.key("KEYCODE_DPAD_LEFT") }
    @objc private func dpadRight() { adb.key("KEYCODE_DPAD_RIGHT") }
    @objc private func dpadCenter() { adb.key("KEYCODE_DPAD_CENTER") }
    @objc private func backAction() { adb.key("KEYCODE_BACK") }
    @objc private func homeAction() { adb.key("KEYCODE_HOME") }
    @objc private func menuAction() { adb.key("KEYCODE_MENU") }
}
