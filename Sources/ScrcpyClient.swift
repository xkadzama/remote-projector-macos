// Клиент scrcpy: единственный надёжный способ получить с этого проектора живое видео
// и управление с малой задержкой.
//
// Почему именно так. Штатный `screenrecord` на устройстве отдаёт кадры только при
// изменении картинки, и то по одному — для удалённого рабочего стола это непригодно.
// `screencap` даёт 0.6 кадра в секунду. А сервер scrcpy работает через MediaCodec
// с поверхностью и отдаёт 1280x720 с частотой до 30 кадров/с, плюс отдельный канал
// управления: тапы, свайпы, клавиши и текст уходят туда без задержки на запуск
// процесса adb.
//
// Формат потока (проверен на scrcpy-server 5.0.1):
//   заголовок 81 байт: 1 байт (0) + 64 байта имени устройства + кодек(4) + ширина(4) + высота(4)
//   далее пакеты: 8 байт метки времени (старший бит = «это настройки кодека») + 4 байта длины + данные
//   данные — H.264 в Annex-B (старт-коды 00 00 00 01)

import Foundation
import VideoToolbox
import CoreImage
import AppKit

/// Пишет отладочные сообщения в /tmp/proyektor.log — читать удобнее, чем консоль.
func dlog(_ msg: String) {
    let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(msg)\n"
    let path = "/tmp/proyektor.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

final class ScrcpyClient {
    // ---------------------------------------------------------------- состояние

    private let adb: ADB
    private(set) var running = false

    /// Кадр готов.
    var onFrame: ((CGImage) -> Void)?
    /// Поток остановился; текст — причина.
    var onStop: ((String) -> Void)?
    /// Пришёл первый кадр.
    var onFirstFrame: (() -> Void)?

    private var serverProcess: Process?
    private var videoSocket: Int32 = -1
    private var controlSocket: Int32 = -1
    private var readThread: Thread?
    private let decoder = H264Decoder()
    private var deviceWidth = 1280
    private var deviceHeight = 720
    private var gotFirstFrame = false
    private let lock = NSLock()

    /// Порт для проброса. Меняем, если занят.
    private var port = 27183

    /// Максимальная сторона кадра: 1280 — полное разрешение, меньше — быстрее.
    var maxSize = 640

    init(adb: ADB) {
        self.adb = adb
        decoder.onImage = { [weak self] image in
            guard let self else { return }
            if !self.gotFirstFrame {
                dlog("первый кадр \(image.width)x\(image.height)")
                // scrcpy при downscale не обновляет заголовок, поэтому реальный
                // размер кадра берём из декодированного изображения: по нему
                // считаются координаты кликов и он же сообщается серверу.
                self.deviceWidth = image.width
                self.deviceHeight = image.height
            }
            DispatchQueue.main.async {
                if !self.gotFirstFrame {
                    self.gotFirstFrame = true
                    self.onFirstFrame?()
                }
                self.onFrame?(image)
            }
        }
    }

    // ---------------------------------------------------------------- запуск

    /// Поднимает сервер на проекторе и открывает сокеты.
    func start() {
        guard !running else { return }
        running = true
        gotFirstFrame = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let error = self.launch() else { return }
            DispatchQueue.main.async {
                self.running = false
                self.onStop?(error)
            }
        }
    }

    /// Вся подготовка: залить jar, пробросить порт, запустить сервер, открыть сокеты.
    private func launch() -> String? {
        // 1. Сервер scrcpy. Он удаляет свой файл при выходе, поэтому заливаем каждый раз.
        guard let jar = ScrcpyClient.findServerJar() else {
            dlog("jar не найден")
            return "не найден scrcpy-server (установите scrcpy: brew install scrcpy)"
        }
        dlog("jar: \(jar)")
        let remote = "/data/local/tmp/sc-remote.jar"
        let pushOut = adb.run(["push", jar, remote])
        dlog("push: \(pushOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        _ = adb.run(["shell", "chmod 644 \(remote)"])
        // Проверяем, что файл действительно лёг.
        let check = adb.run(["shell", "ls -l \(remote) 2>/dev/null | wc -l"])
        if (Int(check.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 0 {
            return "не удалось загрузить сервер на проектор"
        }

        // 2. Проброс порта. Если занят — берём следующий.
        _ = adb.run(["forward", "--remove-all"])
        var forwarded = false
        for candidate in 27183...27190 {
            let out = adb.run(["forward", "tcp:\(candidate)", "localabstract:scrcpy"])
            dlog("forward \(candidate): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            if !out.lowercased().contains("error") && !out.lowercased().contains("cannot") {
                port = candidate
                forwarded = true
                break
            }
        }
        guard forwarded else { return "не удалось пробросить порт" }

        // 3. Запуск сервера. Порядок важен: он слушает сокет и ждёт два подключения.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb.adbPath)
        p.arguments = [
            "-s", "\(adb.host):\(adb.port)", "shell",
            "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server 5.0.1 "
                + "log_level=info audio=false control=true max_fps=30 max_size=\(maxSize) tunnel_forward=true"
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return "не удалось запустить сервер scrcpy"
        }
        p.terminationHandler = { proc in
            dlog("сервер завершился, код \(proc.terminationStatus)")
        }
        serverProcess = p
        // Вычитываем лог сервера в файл: по нему видно, что он делает.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    dlog("сервер: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        // 4. Ждём, пока сервер создаст свой сокет на устройстве.
        //
        // Подключаться «наугад» нельзя: adb поднимает локальный слушатель сразу,
        // и соединение, попавшее до готовности сервера, занимает одно из двух
        // принимаемых мест и тут же закрывается — сервер от этого завершается.
        // Поэтому сначала дожидаемся появления сокета, потом подключаемся один раз.
        var socketReady = false
        for _ in 0..<60 {
            let out = adb.run(["shell", "cat /proc/net/unix 2>/dev/null | grep -c scrcpy"], timeout: 8)
            if (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                socketReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        dlog(socketReady ? "сокет сервера готов" : "сокет сервера не появился")
        // Небольшая пауза: сервер печатает приветствие и переходит к accept.
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Ровно два соединения: первое — видео, второе — управление.
        //    Порядок строгий, сервер различает их по очереди подключения.
        guard let video = ScrcpyClient.connectWithRetry(port: port, attempts: 20) else {
            dlog("видео-сокет не открылся")
            stop()
            return "сервер scrcpy не отвечает (порт \(port))"
        }
        guard let control = ScrcpyClient.connectWithRetry(port: port, attempts: 20) else {
            dlog("канал управления не открылся")
            close(video)
            stop()
            return "не удалось открыть канал управления"
        }
        videoSocket = video
        controlSocket = control
        var noDelay: Int32 = 1
        setsockopt(control, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        ScrcpyClient.setTimeout(control, seconds: 5)
        ScrcpyClient.setTimeout(video, seconds: 120)
        dlog("оба сокета открыты")

        // Заголовок: 1 байт (0) + 64 байта имени + кодек(4) + ширина(4) + высота(4).
        guard let header = readExact(video, 81) else {
            dlog("заголовок не прочитан")
            stop()
            return "сервер не отдал заголовок потока"
        }
        deviceWidth = Int(header[69..<73].reduce(0) { $0 << 8 | Int($1) })
        deviceHeight = Int(header[73..<77].reduce(0) { $0 << 8 | Int($1) })
        if deviceWidth <= 0 || deviceWidth > 8192 || deviceHeight <= 0 || deviceHeight > 8192 {
            deviceWidth = 1280; deviceHeight = 720
        }
        dlog("поток \(deviceWidth)x\(deviceHeight)")
        decoder.configure()

        // 6. Погнали читать кадры.
        let t = Thread { [weak self] in self?.readLoop() }
        t.stackSize = 1 << 20
        t.start()
        readThread = t
        return nil
    }

    /// Ищет установленный scrcpy-server.
    static func findServerJar() -> String? {
        let candidates = [
            "/opt/homebrew/Cellar/scrcpy/5.0.1/share/scrcpy/scrcpy-server",
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Через brew: путь зависит от версии, поэтому ищем в Cellar.
        let cellar = "/opt/homebrew/Cellar/scrcpy"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            for v in versions {
                let path = "\(cellar)/\(v)/share/scrcpy/scrcpy-server"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    /// Ограничивает ожидание в recv/send, чтобы поток не висел вечно.
    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Подключается к проброшенному порту, повторяя попытки.
    private static func connectWithRetry(port: Int, attempts: Int) -> Int32? {
        for _ in 0..<attempts {
            let fd = connect(port: port)
            if fd >= 0 { return fd }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private static func connect(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Читает ровно n байт или nil при обрыве.
    private func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: got)
                return recv(fd, base, n - got, 0)
            }
            if r <= 0 { return nil }
            got += r
        }
        return out
    }

    // ---------------------------------------------------------------- чтение видео

    /// Читает пакеты и отдаёт их декодеру.
    private func readLoop() {
        var packets = 0
        var bytes = 0
        var lastPackets = 0
        var lastBytes = 0
        var lastReport = Date()
        var reportAt = Date().addingTimeInterval(5)
        while running {
            guard videoSocket >= 0 else { break }
            // Заголовок пакета: 8 байт pts + 4 байта размера.
            guard let head = readExact(videoSocket, 12) else {
                dlog("видео-сокет закрыт (пакетов \(packets))")
                break
            }
            let pts = head[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let size = Int(head[8..<12].reduce(0) { $0 << 8 | Int($1) })
            // Старший бит метки — признак пакета настроек кодека.
            let isConfig = (pts & (1 << 63)) != 0
            if size <= 0 || size > 8_000_000 {
                dlog("битый размер пакета: \(size)")
                break
            }
            guard let payload = readExact(videoSocket, size) else {
                dlog("обрыв на теле пакета (ожидали \(size) байт)")
                break
            }
            packets += 1
            bytes += size
            if Date() > reportAt {
                let dt = Date().timeIntervalSince(lastReport)
                lastReport = Date()
                reportAt = Date().addingTimeInterval(5)
                dlog("пакетов \(packets - lastPackets) за \(String(format: "%.1f", dt))с "
                     + "= \(String(format: "%.1f", Double(packets - lastPackets) / dt)) fps, "
                     + "\((bytes - lastBytes) / 1024) КБ")
                lastPackets = packets
                lastBytes = bytes
            }
            decoder.feed(Data(payload), isConfig: isConfig)
        }
        guard running else { return }
        running = false
        // Обрыв не должен требовать ручного вмешательства: поднимаем поток заново.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStop?("переподключаюсь…")
            self.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.start()
            }
        }
    }

    // ---------------------------------------------------------------- управление

    /// Отправляет сообщение в канал управления.
    private func send(_ data: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard controlSocket >= 0 else { return }
        var sent = 0
        while sent < data.count {
            let r = data.withUnsafeBytes { raw -> Int in
                Darwin.send(controlSocket, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if r <= 0 { return }
            sent += r
        }
    }

    /// Касание: down/move/up в координатах экрана проектора.
    func touch(action: TouchAction, x: Int, y: Int) {
        var msg: [UInt8] = [2, action.rawValue]
        msg += be64(UInt64(bitPattern: -1))          // идентификатор указателя
        msg += be32(UInt32(bitPattern: Int32(x)))
        msg += be32(UInt32(bitPattern: Int32(y)))
        msg += be16(UInt16(deviceWidth)) + be16(UInt16(deviceHeight))
        msg += be16(0xFFFF)                          // давление
        msg += be32(0) + be32(0)                     // кнопки и модификаторы
        send(msg)
    }

    enum TouchAction: UInt8 {
        case down = 0, up = 1, move = 2
    }

    /// Нажатие клавиши. action: 0 — вниз, 1 — вверх.
    func key(_ code: UInt32, action: UInt8 = 0) {
        var msg: [UInt8] = [0, action]
        msg += be32(code)
        msg += be32(0)      // повтор
        msg += be32(0)      // модификаторы
        send(msg)
    }

    /// Нажатие и отпускание одной клавиши.
    func press(_ code: UInt32) {
        key(code, action: 0)
        key(code, action: 1)
    }

    /// Ввод текста целиком — так быстрее, чем по символу.
    func text(_ s: String) {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return }
        var msg: [UInt8] = [1]
        msg += be32(UInt32(bytes.count))
        msg += bytes
        send(msg)
    }

    /// Прокрутка колесом.
    func scroll(x: Int, y: Int, dx: Int, dy: Int) {
        var msg: [UInt8] = [3]
        msg += be32(UInt32(bitPattern: Int32(x)))
        msg += be32(UInt32(bitPattern: Int32(y)))
        msg += be16(UInt16(deviceWidth)) + be16(UInt16(deviceHeight))
        msg += be16(UInt16(bitPattern: Int16(clamping: dx)))
        msg += be16(UInt16(bitPattern: Int16(clamping: dy)))
        msg += be32(0)
        send(msg)
    }

    /// Числовой KEYCODE Android по имени из интерфейса.
    static func keyCode(named name: String) -> UInt32? {
        switch name {
        case "KEYCODE_DPAD_UP": return 19
        case "KEYCODE_DPAD_DOWN": return 20
        case "KEYCODE_DPAD_LEFT": return 21
        case "KEYCODE_DPAD_RIGHT": return 22
        case "KEYCODE_DPAD_CENTER": return 23
        case "KEYCODE_BACK": return 4
        case "KEYCODE_HOME": return 3
        case "KEYCODE_MENU": return 82
        case "KEYCODE_TAB": return 61
        case "KEYCODE_DEL": return 67
        case "KEYCODE_FORWARD_DEL": return 112
        case "KEYCODE_MOVE_HOME": return 122
        case "KEYCODE_MOVE_END": return 123
        case "KEYCODE_PAGE_UP": return 92
        case "KEYCODE_PAGE_DOWN": return 93
        case "KEYCODE_SPACE": return 62
        case "KEYCODE_ENTER": return 66
        case "KEYCODE_ESCAPE": return 111
        case "KEYCODE_VOLUME_UP": return 24
        case "KEYCODE_VOLUME_DOWN": return 25
        case "KEYCODE_POWER": return 26
        case "KEYCODE_MEDIA_PLAY_PAUSE": return 85
        case "KEYCODE_MEDIA_NEXT": return 87
        case "KEYCODE_MEDIA_PREVIOUS": return 88
        default: return nil
        }
    }

    /// Размер кадра — нужен интерфейсу, чтобы правильно считать координаты.
    var screenSize: (w: Int, h: Int) { (deviceWidth, deviceHeight) }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    private func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(v >> (56 - $0 * 8) & 0xff) }
    }

    // ---------------------------------------------------------------- остановка

    func stop() {
        running = false
        lock.lock()
        if videoSocket >= 0 { close(videoSocket); videoSocket = -1 }
        if controlSocket >= 0 { close(controlSocket); controlSocket = -1 }
        lock.unlock()
        serverProcess?.terminate()
        serverProcess = nil
        _ = adb.run(["shell", "pkill -f com.genymobile.scrcpy.Server"], timeout: 8)
        _ = adb.run(["forward", "--remove-all"], timeout: 8)
        decoder.reset()
    }
}

// -------------------------------------------------------------------- декодер

/// Декодер H.264: принимает пакеты scrcpy, отдаёт кадры.
final class H264Decoder {
    var onImage: ((CGImage) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var ready = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func configure() {
        reset()
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sps = nil
        pps = nil
        ready = false
    }

    deinit { reset() }

    /// Принимает пакет. isConfig — в нём лежат SPS/PPS, а не кадр.
    private var fed = 0
    private var decodedCalls = 0
    private var sessionErr: OSStatus = 0

    func feed(_ payload: Data, isConfig: Bool) {
        fed += 1
        // Пакет может содержать и параметры (SPS/PPS), и сам кадр. Поэтому идём
        // по NAL по порядку: встретили параметры — запомнили, встретили кадр —
        // декодируем. Флаг isConfig лишь подсказка, полагаться на него нельзя.
        for nal in H264Decoder.splitNALUnits(payload) {
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7:
                sps = nal
                ready = false
                dlog("SPS \(nal.count) байт, профиль \(nal.count > 1 ? Int(nal[1]) : 0)")
            case 8:
                pps = nal
                ready = false
                dlog("PPS \(nal.count) байт")
            case 1, 5:
                // Кадр. Собираем сессию ровно перед первым кадром.
                if !ready { buildSession() }
                guard ready else { continue }
                decode(nal)
            default:
                break
            }
        }
        if fed <= 3 || fed % 40 == 0 {
            let nals = H264Decoder.splitNALUnits(payload).compactMap { $0.first.map { $0 & 0x1f } }
            dlog("feed #\(fed) байт=\(payload.count) NAL=\(nals) ready=\(ready)")
        }
    }

    /// Режет Annex-B поток на отдельные NAL.
    static func splitNALUnits(_ data: Data) -> [Data] {
        var starts: [Int] = []
        var i = 0
        let n = data.count
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            while i + 3 < n {
                if b[i] == 0, b[i + 1] == 0 {
                    if b[i + 2] == 1 { starts.append(i); i += 3; continue }
                    if b[i + 2] == 0, i + 3 < n, b[i + 3] == 1 { starts.append(i); i += 4; continue }
                }
                i += 1
            }
        }
        guard !starts.isEmpty else { return [] }
        var out: [Data] = []
        for idx in 0..<starts.count {
            let begin = starts[idx]
            let end = idx + 1 < starts.count ? starts[idx + 1] : n
            var payload = begin + 3
            if payload < end, data[payload] == 0 { payload += 1 }
            payload += 1
            if payload < end { out.append(data.subdata(in: payload..<end)) }
        }
        return out
    }

    private func buildSession() {
        guard let sps, let pps else { return }
        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            sessionErr = status
            dlog("format err \(status)")
            return
        }
        format = description

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, let refCon else { return }
                Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue().emit(imageBuffer)
            },
            decompressionOutputRefCon: refCon)
        var newSession: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession)
        guard st == noErr, let newSession else {
            sessionErr = st
            dlog("session err \(st)")
            return
        }
        session = newSession
        ready = true
        dlog("сессия декодера готова")
    }

    fileprivate func emit(_ buffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        onImage?(cg)
    }

    private func decode(_ nal: Data) {
        guard let session, let format else { return }
        var avcc = Data()
        var length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
        avcc.append(nal)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }

        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return }

        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(Date().timeIntervalSince1970 * 1_000_000), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr,
              let sample else { return }

        var flagsOut = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: VTDecodeFrameFlags(rawValue: 0),
            frameRefcon: nil, infoFlagsOut: &flagsOut)
        decodedCalls += 1
        if st != noErr {
            dlog("decode err \(st) (вызов \(decodedCalls))")
            // Ошибка данных — сбрасываем сессию, следующий кадр соберёт её заново.
            if st == -12712 || st == -12909 {
                ready = false
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }
}
