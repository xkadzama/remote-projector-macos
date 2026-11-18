// ADB-клиент: держит одно TCP-соединение к adb-серверу и постоянную shell-сессию.
// Постоянная сессия — ключ к скорости: каждая отдельная команда `adb shell` стоит
// ~150 мс, а команды в уже открытой сессии уходят по 40 штук в секунду.

import Foundation

final class ADB {
    /// Адрес проектора в сети. Это только значение по умолчанию: реальный адрес
    /// вводится в поле подключения и живёт до закрытия приложения.
    var host: String = "192.168.1.50"
    var port: Int = 5555

    /// Путь к бинарнику adb. Приложение ищет его само, но путь можно задать вручную.
    var adbPath: String = ADB.findADB()

    private var shellProcess: Process?
    private var shellInput: FileHandle?
    private let shellQueue = DispatchQueue(label: "adb.shell")
    private let stateLock = NSLock()
    private var connected = false

    // ---------------------------------------------------------------- поиск adb

    static func findADB() -> String {
        let candidates = [
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Последняя попытка: PATH из окружения.
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let path = "\(dir)/adb"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/env"
    }

    // ---------------------------------------------------------------- подключение

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected
    }

    /// Подключается к проектору. Возвращает текст ошибки или nil при успехе.
    func connect() -> String? {
        dlog("adb путь: \(adbPath)")
        _ = run(["kill-server"])
        let out = run(["connect", "\(host):\(port)"])
        guard !out.contains("cannot") && !out.contains("failed") && !out.contains("refused") else {
            return out.isEmpty ? "не удалось подключиться" : out
        }
        // Ждём, пока устройство появится в списке.
        for _ in 0..<12 {
            let list = run(["devices"])
            if list.split(separator: "\n").contains(where: { $0.contains("\(host):\(port)") && $0.contains("device") }) {
                stateLock.lock(); connected = true; stateLock.unlock()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return "устройство не появилось в списке (проверьте, что на проекторе включена отладка по сети)"
    }

    /// Полностью закрывает доступ к проектору.
    ///
    /// Одного `adb disconnect` недостаточно: он убирает запись из списка, но
    /// сервер adb на Mac держит открытые соединения и через пару секунд
    /// возвращает устройство обратно (проверено — `adb devices` снова показывает
    /// `device`). Поэтому сначала снимаем проброс портов, затем disconnect,
    /// а в конце гасим локальный сервер adb: только это рвёт связь по-настоящему.
    func disconnect() {
        closeShell()
        // Проброс портов — это то, через что идёт видео и управление.
        _ = run(["forward", "--remove-all"])
        _ = run(["disconnect", "\(host):\(port)"])
        // Гасим локальный сервер: без него соединений с проектором нет вообще.
        _ = run(["kill-server"], timeout: 10)
        stateLock.lock(); connected = false; stateLock.unlock()
    }

    /// Выполняет короткую команду и возвращает её вывод.
    @discardableResult
    func run(_ args: [String], timeout: TimeInterval = 25) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["-s", "\(host):\(port)"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return "adb не найден: \(adbPath)"
        }
        // Читаем в фоне, чтобы не блокировать поток до EOF, и ждём завершения с потолком.
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // ---------------------------------------------------------------- shell-сессия

    /// Открывает постоянную shell-сессию: команды уходят в неё и выполняются мгновенно.
    private func openShell() -> Bool {
        if shellProcess?.isRunning == true, shellInput != nil { return true }
        closeShell()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["-s", "\(host):\(port)", "shell"]
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        do {
            try p.run()
        } catch {
            return false
        }
        shellProcess = p
        shellInput = input.fileHandleForWriting
        // Вычитываем вывод в фоне, чтобы труба не переполнилась и команды не встали.
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
            }
        }
        // Даём сессии подняться.
        Thread.sleep(forTimeInterval: 0.3)
        return true
    }

    private func closeShell() {
        shellInput?.closeFile()
        shellInput = nil
        shellProcess?.terminate()
        shellProcess = nil
    }

    /// Отправляет строку в постоянную сессию. Быстро: ~25 мс на команду.
    func send(_ command: String) {
        shellQueue.async {
            if !self.openShell() {
                _ = self.run(["shell", command])
                return
            }
            guard let input = self.shellInput else { return }
            if let data = (command + "\n").data(using: .utf8) {
                input.write(data)
            }
        }
    }

    /// То же, но с ожиданием выполнения — для команд, чей результат нужен сразу.
    func sendSync(_ command: String) {
        shellQueue.sync {
            if !openShell() {
                _ = run(["shell", command])
                return
            }
            guard let input = shellInput else { return }
            if let data = (command + "\n").data(using: .utf8) {
                input.write(data)
            }
        }
    }

    // ---------------------------------------------------------------- ввод

    /// Тап по координатам экрана проектора.
    func tap(x: Int, y: Int) {
        send("input tap \(x) \(y)")
    }

    /// Нажатие кнопки пульта по имени, например KEYCODE_DPAD_UP.
    func key(_ name: String) {
        send("input keyevent \(name)")
    }

    /// Ввод текста. Пробелы заменяются на %s — так их понимает input text.
    func text(_ s: String) {
        guard !s.isEmpty else { return }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "'\\''")
                       .replacingOccurrences(of: " ", with: "%s")
        send("input text '\(escaped)'")
    }

    /// Прокрутка колесом: roll работает от трекбола и не требует координат.
    func scroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        send("input roll \(dx) \(dy)")
    }

    /// Начало движения пальца для перетаскивания.
    func motionDown(x: Int, y: Int) {
        send("input motionevent DOWN \(x) \(y)")
    }

    func motionMove(x: Int, y: Int) {
        send("input motionevent MOVE \(x) \(y)")
    }

    func motionUp(x: Int, y: Int) {
        send("input motionevent UP \(x) \(y)")
    }

    // ---------------------------------------------------------------- прочее

    /// Размер экрана проектора в пикселях.
    func screenSize() -> (w: Int, h: Int) {
        let out = run(["shell", "wm", "size"])
        // Пример: Physical size: 1280x720
        for line in out.split(separator: "\n") where line.contains("size:") {
            let parts = line.split(separator: ":")
            if parts.count == 2 {
                let dims = parts[1].trimmingCharacters(in: .whitespaces).split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                    return (w, h)
                }
            }
        }
        return (1280, 720)
    }

    /// Состояние VPN: поднят ли туннель.
    func vpnIsUp() -> Bool {
        let out = run(["shell", "ip addr show tun0 2>/dev/null | grep -c inet"])
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// Имя модели проектора — для заголовка окна.
    func deviceName() -> String {
        let out = run(["shell", "getprop ro.product.model"])
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Проектор" : name
    }
}
