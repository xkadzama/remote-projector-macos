// Точка входа приложения.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// Тёмная системная тема должна достаться и нашему окну: иначе панель
// с материалом .headerView рисуется светлой поверх тёмных контролов.
// Переменная PROYEKTOR_THEME переопределяет тему — нужна для проверки
// светлого оформления, когда сама система тёмная.
switch ProcessInfo.processInfo.environment["PROYEKTOR_THEME"] {
case "light": app.appearance = NSAppearance(named: .aqua)
case "dark": app.appearance = NSAppearance(named: .darkAqua)
default:
    if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
        app.appearance = NSAppearance(named: .darkAqua)
    }
}
app.run()
