// Экран проектора: рисует кадры и превращает события мыши и клавиатуры Mac
// в тапы и нажатия на проекторе.

import AppKit
import Foundation

/// Вид, который показывает кадр с проектора и принимает ввод.
final class ScreenView: NSView {
    /// Кадр, который сейчас на экране.
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Сюда уходит ввод: координаты уже переведены в пиксели проектора.
    var onTap: ((Int, Int) -> Void)?
    var onKey: ((String) -> Void)?
    var onText: ((String) -> Void)?
    var onScroll: ((Int, Int) -> Void)?
    /// Перетаскивание: отдаём одно событие на весь жест.
    var onDrag: ((DragPhase, Int, Int) -> Void)?
    /// Движение мыши без нажатой кнопки — для режима «мышь как пульт».
    var onMove: ((Int, Int) -> Void)?
    /// Короткий клик (нажал и отпустил почти на месте).
    var onTapAt: ((Int, Int) -> Void)?

    /// Режим «мышь как пульт»: главный экран Android TV не принимает касания,
    /// поэтому движение мыши переводится в нажатия стрелок.
    var dpadMode = true

    enum DragPhase { case begin, move, end }

    /// Размер экрана проектора в пикселях.
    var screenSize = CGSize(width: 1280, height: 720) {
        didSet { needsLayout = true; needsDisplay = true }
    }

    /// Прямоугольник, в который вписан кадр (с сохранением пропорций).
    private var videoRect: CGRect = .zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // Отслеживаем мышь над видео, чтобы получать mouseMoved.
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: videoRect.isEmpty ? bounds : videoRect,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard dpadMode, let (x, y) = devicePoint(event) else { return }
        onMove?(x, y)
    }

    // ---------------------------------------------------------------- отрисовка

    override func draw(_ dirtyRect: NSRect) {
        // Экран больше не заливает фон: подложку рисует ScreenContainer,
        // чтобы скруглённые углы совпадали у рамки и у кадра.
        guard let image else {
            drawPlaceholder()
            return
        }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        // Кадр скругляем по тем же углам, что и подложку — иначе видны «уши».
        let clip = CGPath(roundedRect: videoRect,
                          cornerWidth: Style.Metric.videoCorner,
                          cornerHeight: Style.Metric.videoCorner,
                          transform: nil)
        cg.addPath(clip)
        cg.clip()
        cg.interpolationQuality = .high
        cg.draw(image, in: videoRect)
        cg.restoreGState()
    }

    /// Заглушка, пока нет кадра: символ экрана и пояснение по центру.
    private func drawPlaceholder() {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        let text = "Нет соединения с проектором" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1),
        ]
        let textSize = text.size(withAttributes: attrs)
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = 12
        let total = iconSize.height + gap + textSize.height
        let top = (bounds.height - total) / 2

        if let icon {
            let rect = CGRect(x: (bounds.width - iconSize.width) / 2,
                              y: top + textSize.height + gap,
                              width: iconSize.width, height: iconSize.height)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5,
                      respectFlipped: true, hints: nil)
        }
        text.draw(at: CGPoint(x: (bounds.width - textSize.width) / 2, y: top),
                  withAttributes: attrs)
    }

    override func layout() {
        super.layout()
        guard let image else {
            videoRect = bounds
            return
        }
        // Вписываем кадр в окно, сохраняя пропорции, по центру.
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { videoRect = bounds; return }
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale
        let h = ih * scale
        videoRect = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    // ---------------------------------------------------------------- координаты

    /// Переводит точку из окна в пиксели экрана проектора.
    private func devicePoint(_ event: NSEvent) -> (Int, Int)? {
        let local = convert(event.locationInWindow, from: nil)
        guard videoRect.contains(local), videoRect.width > 0, videoRect.height > 0 else { return nil }
        // Вид перевёрнут: AppKit считает Y снизу, экран проектора — сверху.
        let rx = (local.x - videoRect.minX) / videoRect.width
        let ry = 1.0 - (local.y - videoRect.minY) / videoRect.height
        let x = Int((rx * screenSize.width).rounded())
        let y = Int((ry * screenSize.height).rounded())
        return (max(0, min(Int(screenSize.width) - 1, x)), max(0, min(Int(screenSize.height) - 1, y)))
    }

    // ---------------------------------------------------------------- мышь

    override func mouseDown(with event: NSEvent) {
        guard let (x, y) = devicePoint(event) else { return }
        onDrag?(.begin, x, y)
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let (x, y) = devicePoint(event) else { return }
        onDrag?(.move, x, y)
    }

    override func mouseUp(with event: NSEvent) {
        if dpadMode {
            if let (x, y) = devicePoint(event) { onTapAt?(x, y) }
            return
        }
        guard dragging else { return }
        dragging = false
        // Отпускание всегда в последней точке: если курсор вышел за кадр, берём край.
        let local = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(max(local.x, videoRect.minX), videoRect.maxX),
                              y: min(max(local.y, videoRect.minY), videoRect.maxY))
        let rx = videoRect.width > 0 ? (clamped.x - videoRect.minX) / videoRect.width : 0
        let ry = videoRect.height > 0 ? 1.0 - (clamped.y - videoRect.minY) / videoRect.height : 0
        let x = Int((rx * screenSize.width).rounded())
        let y = Int((ry * screenSize.height).rounded())
        onDrag?(.end, max(0, min(Int(screenSize.width) - 1, x)), max(0, min(Int(screenSize.height) - 1, y)))
    }

    override func scrollWheel(with event: NSEvent) {
        // На пультовом Android колесо работает как прокрутка списка.
        let dy = event.hasPreciseScrollingDeltas ? Int(event.scrollingDeltaY / 3) : Int(event.scrollingDeltaY)
        guard dy != 0 else { return }
        onScroll?(0, dy)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Правая кнопка — «назад» на Android.
        onKey?("KEYCODE_BACK")
    }

    // ---------------------------------------------------------------- клавиатура

    override func keyDown(with event: NSEvent) {
        // Сначала пробуем как команду, потом как текст.
        if let name = ScreenView.keyCode(for: event) {
            onKey?(name)
            return
        }
        if let chars = event.characters, !chars.isEmpty {
            let filtered = chars.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }
            let s = String(String.UnicodeScalarView(filtered))
            if !s.isEmpty { onText?(s) }
        }
    }

    /// Переводит клавишу macOS в KEYCODE Android. nil — значит это обычный текст.
    static func keyCode(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 126: return "KEYCODE_DPAD_UP"
        case 125: return "KEYCODE_DPAD_DOWN"
        case 123: return "KEYCODE_DPAD_LEFT"
        case 124: return "KEYCODE_DPAD_RIGHT"
        case 36, 76: return "KEYCODE_DPAD_CENTER"     // Return / Enter
        case 53: return "KEYCODE_BACK"                // Esc
        case 48: return "KEYCODE_TAB"
        case 51: return "KEYCODE_DEL"                 // Backspace
        case 117: return "KEYCODE_FORWARD_DEL"
        case 115: return "KEYCODE_MOVE_HOME"
        case 119: return "KEYCODE_MOVE_END"
        case 116: return "KEYCODE_PAGE_UP"
        case 121: return "KEYCODE_PAGE_DOWN"
        case 49: return "KEYCODE_SPACE"
        default: break
        }
        // Стрелки с модификатором не должны превращаться в dpad.
        return nil
    }
}
