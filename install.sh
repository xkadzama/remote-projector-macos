#!/bin/bash
# Сборка и установка приложения «Проектор» для macOS.
set -e
cd "$(dirname "$0")"

echo "==> проверяю окружение"
command -v swiftc >/dev/null 2>&1 || { echo "Нужен Xcode или Command Line Tools: xcode-select --install"; exit 1; }
command -v adb >/dev/null 2>&1 || echo "Внимание: adb не в PATH, приложение найдёт его само"

echo "==> собираю приложение"
./build.sh

echo "==> ставлю в /Applications"
rm -rf "/Applications/Проектор.app"
cp -R "Проектор.app" "/Applications/Проектор.app"
echo "Готово. Запуск: open '/Applications/Проектор.app'"
