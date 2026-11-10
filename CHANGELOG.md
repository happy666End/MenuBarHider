# Changelog

## Не выпущено

### Исправлено

- Исправлено открытие панели виджетов по часам на нескольких мониторах, включая края области нажатия и изменение конфигурации экранов.
- Частичный сбой Accessibility-сканирования больше не стирает выбор скрытых приложений и не скрывает видимую иконку с общим системным переключателем.
- Возврат к прежнему списку разрешённых приложений теперь учитывает ещё выполняющуюся активацию скрытия.
- Явное восстановление видимости отменяет автоматическое скрытие и отложенное ожидание разрешения Accessibility.
- После переноса в Applications новая копия запускается после завершения прежней и освобождения блокировки экземпляра.
- Команды разработки больше не завершают приложение принудительно: установка проверяет новую сборку, сохраняет прежнюю копию и откатывает замену при ошибке или обычном прерывании.

### Добавлено

- Экспериментальный способ скрытия через системные настройки строки меню (`trackedApplications`) с доступом только к папке Control Center, отдельным включением и восстановлением изменённых переключателей. Служебные записи без идентификатора сохраняются. Неудачное восстановление отображается пользователю и блокирует смену способа скрытия.
- Защита от одновременного запуска нескольких экземпляров приложения.
- Лицензия включена в приложение; архивы релиза сохраняются по версиям с проверенными подписями и контрольными суммами.

## 0.1.2 — 2026-10-02

### Fixed

- Apps that live only in the menu bar (Raycast, Tunnelblick and most others) no longer stay
  hidden when launched while the bar is collapsed. macOS does not post its launch
  notification for them, so the app now watches the list of running apps instead.
- A copy started outside *Applications* (the disk image, *Downloads*, a translocated download)
  no longer hides its own `»`, which left no way to expand the bar. It offers to move itself
  to *Applications* and relaunch, and keeps hiding off until it is moved.

### Added

- Releases ship a signed, notarized disk image next to the zip.

## 0.1.1 — 2026-09-26

### Fixed

- Time Machine, VPN and other Apple menu extras placed between `|` and `»` now hide with
  the rest ([#1](https://github.com/happy666End/MenuBarHider/issues/1)). While the bar is
  collapsed they are unloaded, so System Settings shows their menu bar toggle as off; they
  come back on expand, on quit and on the next launch after a crash.

## 0.1.0 — 2026-09-21

First release: hides menu bar icons on macOS 27, where Hidden Bar, Ice and most other
managers stopped working.
