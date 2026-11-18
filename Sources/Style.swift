// Оформление в стиле macOS: прозрачный заголовок, панель инструментов,
// SF Symbols, единая сетка отступов. Здесь только стиль — логика в других файлах.
//
// Принципы, которых держимся:
//   • системные контролы и нативные размеры — ничего «нарисованного» вручную;
//   • сетка отступов 8/12/16/20, как в приложениях Apple;
//   • содержимое уходит под прозрачный заголовок (как в Finder и QuickTime);
//   • SF Symbols вместо эмодзи — они монохромные и меняются вместе с системой;
//   • один акцентный цвет: systemAccentColor на главном действии.

import AppKit

// ------------------------------------------------------------------ палитра

enum Style {
    /// Фон окна: системный, поэтому одинаково хорошо выглядит в светлой и тёмной теме.
    static var windowBackground: NSColor { .windowBackgroundColor }

    /// Подложка вокруг экрана проектора. Почти чёрная — так кадр читается
    /// и в светлой теме, и в тёмной, как в плеере QuickTime.
    static let screenBackground = NSColor(calibratedWhite: 0.07, alpha: 1)

    /// Вторичный текст: подписи и статус.
    static var secondary: NSColor { .secondaryLabelColor }

    /// Единая сетка отступов.
    enum Metric {
        static let pad: CGFloat = 16
        static let gap: CGFloat = 8
        static let tight: CGFloat = 6
        static let remoteHeight: CGFloat = 30
        /// Скругление подложки экрана.
        static let screenCorner: CGFloat = 12
        /// Скругление самого кадра внутри подложки.
        static let videoCorner: CGFloat = 8
    }
}

// ------------------------------------------------------------- контролы

/// Кнопка-иконка для панели инструментов: SF Symbol, нативная подсветка.
///
/// Название остаётся во всплывающей подсказке — так делают системные панели,
/// где важна компактность.
func makeToolbarButton(symbol: String, tooltip: String,
                       target: AnyObject, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
    let button = NSButton(image: image ?? NSImage(), target: target, action: action)
    button.imagePosition = .imageOnly
    button.bezelStyle = .texturedRounded
    button.toolTip = tooltip
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// Основная кнопка действия — акцентная, как кнопка по умолчанию в диалогах macOS.
///
/// Клавиатурный эквивалент Return здесь НЕ назначаем: в этом приложении Return
/// нажимает «OK» на пульте, и перехватывать его нельзя. Синий цвет задаём
/// через bezelColor, а не через статус кнопки по умолчанию.
func makeAccentButton(title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.bezelColor = .controlAccentColor
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// Кнопка пульта: иконка SF Symbol, ширина тянется по сетке.
func makeRemoteButton(symbol: String, tooltip: String,
                      target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.toolTip = tooltip
    button.imagePosition = .imageOnly
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
        // Чуть крупнее системного: по этим кнопкам жмут мышью прицельно.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = image.withSymbolConfiguration(config)
    }
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return button
}

/// Подпись-статус: вторичный цвет, моноширинный шрифт для адресов и чисел.
func makeStatusLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "Не подключено")
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

// ------------------------------------------------------------- контейнер

/// Подложка экрана: скруглённый тёмный прямоугольник с тонкой светлой рамкой.
///
/// Отдельный вид, потому что рамку надо рисовать поверх кадра, а не под ним:
/// иначе на светлых кадрах край пропадает.
final class ScreenContainer: NSView {
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: Style.Metric.screenCorner,
                                yRadius: Style.Metric.screenCorner)
        Style.screenBackground.setFill()
        path.fill()

        // Рамка. В тёмной теме светлая линия на чёрной подложке бьёт по глазам,
        // поэтому рисуем её отдельно для каждой темы: еле заметный контур,
        // как у окон macOS, а не яркая обводка.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let stroke = dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.09)
            : NSColor(calibratedWhite: 0.0, alpha: 0.12)
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
