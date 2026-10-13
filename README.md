<div align="center">
  <h1>ReqGram</h1>
  <p><strong>Telegram-клиент для iOS с дополнительными настройками приватности и оформления.</strong></p>
  <p>Неофициальный iOS-порт AyuGram на базе Swiftgram и Telegram iOS.</p>
  <p>
    <img src="https://img.shields.io/badge/platform-iOS-334155?style=flat-square" alt="Платформа: iOS">
    <img src="https://img.shields.io/badge/language-Swift-F05138?style=flat-square" alt="Язык: Swift">
    <img src="https://img.shields.io/badge/upstream-Swiftgram-6366F1?style=flat-square" alt="На базе Swiftgram">
  </p>
  <p><a href="#возможности">Возможности</a> · <a href="#ограничения">Ограничения</a> · <a href="#локальная-сборка">Сборка</a> · <a href="#upstream-и-лицензии">Upstream</a></p>
</div>

---

ReqGram — неофициальный iOS-порт AyuGram с дополнительными настройками и встроенными плагинами ReqGram. Проект основан на Swiftgram и Telegram iOS. Новости публикуются в [канале ReqGram](https://t.me/ReqGram), а сборки — в [ReqGram CI](https://t.me/ReqGramCI).

## Возможности

| Возможность | Описание |
| :--- | :--- |
| Режим призрака | Можно отдельно отключить отчёты о прочтении, индикатор набора текста, онлайн-статус и просмотры историй. Для некоторых действий доступны отдельные настройки. |
| Локальная история | Сохранение удалённых сообщений и версий до редактирования, настройки сохранения медиа по типам чатов и лимиту размера, импорт и экспорт базы. |
| Оформление | Маркеры удалённых сообщений, прозрачность, скрытие Premium-статусов и локальные настройки Premium-интерфейса. |
| Внутренние плагины | Настройки Gift ID, отправка подарка по ID, Local Edictor / ZwyLib и настраиваемые анимации текста. |
| Бейджи профилей | Поддержка источников ReqGram, AyuGram и exteraGram с локальным кэшем. |

Реализация и настройки: [`Swiftgram/AyuGram`](Swiftgram/AyuGram), [`AyuSettingsController.swift`](Swiftgram/SGSettingsUI/Sources/AyuSettingsController.swift), [`ReqGramSettingsController.swift`](Swiftgram/SGSettingsUI/Sources/ReqGramSettingsController.swift).

## Ограничения

- **Совместимость:** сборка проверена на **iOS 16.7.10**. Для других версий iOS и моделей устройств совместимость не подтверждена.
- **Частичное локальное сохранение:** клиент сохраняет сообщения и медиа, только если успевает получить их до удаления или изменения. Функция не восстанавливает данные с серверов Telegram и не заменяет резервную копию, поэтому часть содержимого может отсутствовать.
- **Приватность:** режим призрака влияет только на поддерживаемые клиентом действия и не меняет поведение Telegram во всех сценариях. Локальный Premium не предоставляет подписку Telegram Premium и серверные функции этой подписки.
- **Внешние серверы:** подсистема бейджей обращается к источникам ReqGram, AyuGram и exteraGram отдельно от Telegram. Доступность и содержимое этих источников могут меняться, а локальный кэш — устаревать. При обращении сервер получает как минимум IP-адрес устройства. Источники описаны в [`AyuRemoteConfig.swift`](Swiftgram/AyuGram/Sources/AyuRemoteConfig.swift).
- **Хранилище App Group:** если общий контейнер недоступен из-за подписи или entitlements, основное приложение использует отдельный каталог `Application Support/TelegramContainer`, а настройки сохраняются в стандартном `UserDefaults`. Автоматического переноса данных между хранилищами нет, поэтому после смены подписи или entitlements ранее сохранённые данные могут перестать отображаться. Системные расширения `.appex` этот резервный вариант не используют. См. [`SGAppGroupIdentifier.swift`](Swiftgram/SGAppGroupIdentifier/Sources/SGAppGroupIdentifier.swift).
- **Системные расширения и плагины ReqGram:** `--xcodeManagedCodesigning` при генерации проекта отключает системные расширения Share, уведомления, Siri/Intents, виджеты и Broadcast Upload. Внутренние плагины ReqGram при этом не отключаются. Apple Watch по умолчанию не встраивается в сборку.
- **IPA без подписи:** наличие архива не означает, что его можно установить на устройство. Для установки нужны подходящие сертификат, provisioning profile и entitlements. Повторная подпись может ограничить работу системных функций.

## Мои каналы

- [ReqGram](https://t.me/ReqGram) — новости и объявления проекта.
- [ReqGram CI](https://t.me/ReqGramCI) — тестовые и CI-сборки.

## Локальная сборка

### Окружение

Текущие закреплённые значения из [`versions.json`](versions.json):

| Компонент | Версия |
| :--- | :--- |
| Базовая версия приложения (`app`) | `12.9.2` |
| Xcode / deploy Xcode | `26.2` / `26.2` |
| Bazel | `8.4.2` (контрольная сумма закреплена в файле) |
| macOS | `26` |

Для сборки нужны macOS, Python 3, [Xcode](https://developer.apple.com/download/applications/) и полный клон репозитория вместе с submodules. Все команды ниже выполняются из корня репозитория. Система сборки основана на upstream Telegram; версия приложения в таблице не обозначает отдельный релиз ReqGram.

### Конфигурация

1. Получите собственные `api_id` и `api_hash` через [Telegram API](https://core.telegram.org/api/obtaining_api_id).
2. В Xcode создайте вспомогательный iOS-проект. Укажите `Swiftgram` в поле Product Name, задайте уникальный Organization Identifier и выберите свою команду разработчика. Team ID можно найти в Apple Developer либо в поле Organizational Unit сертификата Apple Development в Keychain Access. Для случайной части идентификатора upstream предлагает `openssl rand -hex 8`.
3. Сделайте локальную копию [`template_minimal_development_configuration.json`](build-system/template_minimal_development_configuration.json) вне репозитория. Сохраните остальные поля шаблона, заменив следующие значения своими:

```json
{
  "bundle_id": "<YOUR_UNIQUE_BUNDLE_ID>",
  "api_id": "<YOUR_API_ID>",
  "api_hash": "<YOUR_API_HASH>",
  "team_id": "<YOUR_TEAM_ID>"
}
```

Это фрагмент замен, а не полный конфигурационный файл. В репозитории должны оставаться только шаблонные значения. Конфигурацию с реальными API-данными, сертификаты, provisioning profiles и ключи храните за пределами репозитория, включая приватные копии.

### Проект Xcode

Замените все `<...>` на свои значения. Команда соответствует параметрам [`Make.py`](build-system/Make/Make.py) и генерирует проект для Xcode.

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    generateProject \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --xcodeManagedCodesigning
```

Во время генерации запущенный Xcode закрывается, после чего открывается созданный проект. Перед генерацией сохраните изменения в Xcode.

Имя **ReqGram** относится к приложению, но проект и target унаследованы от Swiftgram: `Telegram/Swiftgram.xcodeproj` и `//Telegram:Swiftgram`. Генератор использует target `Telegram`; параметр `--target=ReqGram` для этой конфигурации не требуется. В Xcode проверьте Signing & Capabilities для своей команды, выберите схему Swiftgram и устройство.

<details>
<summary><strong>Расширенная сборка, подпись и диагностика</strong></summary>

### Явное управление подписью

Вместо минимального шаблона можно скопировать [`appstore-configuration.json`](build-system/appstore-configuration.json). Каталог [`fake-codesigning`](build-system/fake-codesigning) содержит только пример структуры. Для сборки подготовьте собственные сертификаты и provisioning profiles, затем сопоставьте entitlements с образцами в `profiles`.

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    generateProject \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --codesigningInformationPath="<LOCAL_CODESIGNING_DIRECTORY>"
```

В этом режиме iOS extensions не отключаются автоматически: для включённых targets потребуются соответствующие профили. При необходимости используйте `--disableExtensions`.

### IPA для устройства

Для распространения подготовьте distribution profiles подходящего типа и согласованную конфигурацию. Ниже приведён пример сборки IPA с собственной конфигурацией подписи:

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    build \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --codesigningInformationPath="<LOCAL_CODESIGNING_DIRECTORY>" \
    --buildNumber="<BUILD_NUMBER>" \
    --configuration=release_arm64
```

Для запуска на симуляторе подпись устройства не требуется. Upstream также документирует `generateProject --disableProvisioningProfiles`, но в текущем [`ProjectGeneration.py`](build-system/Make/ProjectGeneration.py) этот аргумент не передаётся в Bazel, поэтому его поведение как способа сборки без provisioning profiles не подтверждено.

### Версии и частые ошибки

- Скрипт проверяет версии инструментов по `versions.json`. Глобальный `--overrideXcodeVersion` ставится **до** `build` или `generateProject`; он лишь пропускает проверку Xcode, а не обеспечивает совместимость.
- Ошибка `build-request.json not updated yet` обычно устраняется повторным запуском сборки после завершения или отмены текущей операции в Xcode.
- При `Telegram_xcodeproj: no such package` / отсутствии BUILD в сгенерированном репозитории повторите генерацию проекта.
- Для Apple Watch есть отдельный `--embedWatchApp` в device-сборках. Apple Watch требует собственной действующей подписи, даже если основное приложение уже подписано.

</details>

## Upstream и лицензии

ReqGram использует код и решения из **Telegram iOS** и **Swiftgram**, а также интеграции **AyuGram** и **exteraGram**. Имена Swiftgram, Telegram и AyuGram сохранены в исходниках там, где они относятся к унаследованным модулям и сборке.

| Проект | Ссылки |
| :--- | :--- |
| Telegram iOS | [Исходный код и руководство сборки](https://github.com/TelegramMessenger/Telegram-iOS) · [API](https://core.telegram.org/api) |
| Swiftgram | [Исходный код и руководство сборки](https://github.com/Swiftgram/Telegram-iOS) · [App Store upstream-клиента](https://apps.apple.com/app/id6471879502) |
| Сообщество Swiftgram | [Канал](https://t.me/swiftgram) · [Чат](https://t.me/swiftgramchat) · [Beta, переводы и другие ссылки](https://t.me/s/SwiftgramLinks) |
| AyuGram / exteraGram | [AyuGram](https://github.com/AyuGram) · [exteraGram](https://github.com/exteraSquad) |

Ссылки на App Store и beta относятся к **Swiftgram, не ReqGram**.

При распространении сохраняются copyright-уведомления и требования лицензий upstream-проектов и зависимостей. Приватность репозитория не отменяет эти требования: исходный код изменений предоставляется в соответствии с применимыми лицензиями.

Для стороннего клиента Telegram требуется собственный API ID и явное обозначение неофициального статуса. Приложение не должно создавать впечатление официального клиента Telegram или использовать стандартный логотип Telegram — белый самолётик в синем круге. Пользовательские данные обрабатываются с учётом требований безопасности. Дополнительные требования описаны в [рекомендациях по безопасности](https://core.telegram.org/mtproto/security_guidelines).
