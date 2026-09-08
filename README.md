<div align="center">
  <h1>ReqGram</h1>
  <p><strong>Привычные чаты. Больше личных настроек.</strong></p>
  <p>Неофициальный iOS-порт AyuGram на базе Swiftgram и Telegram iOS.</p>
  <p>
    <img src="https://img.shields.io/badge/platform-iOS-334155?style=flat-square" alt="Платформа: iOS">
    <img src="https://img.shields.io/badge/language-Swift-F05138?style=flat-square" alt="Язык: Swift">
    <img src="https://img.shields.io/badge/upstream-Swiftgram-6366F1?style=flat-square" alt="На базе Swiftgram">
  </p>
  <p><a href="#возможности">Возможности</a> · <a href="#ограничения">Ограничения</a> · <a href="#локальная-сборка">Сборка</a> · <a href="#upstream-и-лицензии">Upstream</a></p>
</div>

---

ReqGram — мой неофициальный iOS-порт AyuGram с дополнительными настройками и встроенными плагинами ReqGram. Основа проекта — Swiftgram и Telegram iOS. Обновления я публикую в [канале ReqGram](https://t.me/ReqGram), а сборки — в [ReqGram CI](https://t.me/ReqGramCI).

## Возможности

| Направление | Что есть в коде |
| :--- | :--- |
| Режим призрака | Можно отдельно отключить отчёты о прочтении, индикатор набора текста, онлайн-статус и просмотры историй. Для некоторых действий доступны отдельные настройки. |
| Локальная история | Сохранение удалённых сообщений и версий до редактирования, настройки сохранения медиа по типам чатов и лимиту размера, импорт и экспорт базы. |
| Оформление | Маркеры удалённых сообщений, прозрачность, скрытие Premium-статусов и локальные настройки Premium-интерфейса. |
| Внутренние плагины | Настройки Gift ID, отправка подарка по ID, Local Edictor / ZwyLib и настраиваемые анимации текста. |
| Бейджи профилей | Поддержка источников ReqGram, AyuGram и exteraGram с локальным кэшем. |

Реализация и настройки: [`Swiftgram/AyuGram`](Swiftgram/AyuGram), [`AyuSettingsController.swift`](Swiftgram/SGSettingsUI/Sources/AyuSettingsController.swift), [`ReqGramSettingsController.swift`](Swiftgram/SGSettingsUI/Sources/ReqGramSettingsController.swift).

## Ограничения

- **Проверка на устройстве:** я проверил сборку на **iOS 16.7.10**. Поведение на других устройствах и версиях iOS может отличаться.
- **Сохранение только по возможности (best effort):** клиент должен успеть получить и сохранить сообщение или медиа. Это не восстановление данных с серверов Telegram и не полноценная резервная копия. Не рассчитывайте на сохранение всего содержимого.
- **Приватность:** режим призрака не гарантирует невидимость во всех сценариях. Локальный Premium не даёт подписку и серверные возможности Telegram Premium.
- **Внешние серверы:** подсистема бейджей обращается к источникам ReqGram, AyuGram и exteraGram, отдельно от Telegram. Их доступность и содержимое не гарантированы; кэш может устаревать. Сетевые запросы раскрывают серверу как минимум IP-адрес. Источники описаны в [`AyuRemoteConfig.swift`](Swiftgram/AyuGram/Sources/AyuRemoteConfig.swift).
- **App Group:** если общий контейнер недоступен из-за подписи/entitlements, основное приложение использует изолированный `Application Support/TelegramContainer`, а настройки переключаются на стандартные `UserDefaults`. Автоматической миграции между общим и приватным хранилищами нет: смена подписи или entitlements может переключить видимые данные. Для `.appex` этот fallback не используется. См. [`SGAppGroupIdentifier.swift`](Swiftgram/SGAppGroupIdentifier/Sources/SGAppGroupIdentifier.swift).
- **iOS extensions и плагины не одно и то же:** `--xcodeManagedCodesigning` при генерации проекта отключает системные расширения (Share, уведомления, Siri/Intents, виджеты, Broadcast Upload). Это не отключение внутренних плагинов ReqGram. Apple Watch по умолчанию не встраивается.
- **Unsigned IPA не готов к установке:** наличие архива не означает наличие действующей подписи. Для обычной установки на устройство нужны подходящие сертификат, provisioning profile и entitlements; повторная подпись может ограничивать системные функции.

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

Нужны macOS, Python 3, [Xcode](https://developer.apple.com/download/applications/) и полный checkout репозитория с submodules. Команды ниже выполняются из корня checkout. Система сборки основана на upstream Telegram; версия приложения в таблице не обозначает отдельный релиз ReqGram.

### Конфигурация

1. Получите собственные `api_id` и `api_hash` через [Telegram API](https://core.telegram.org/api/obtaining_api_id).
2. Создайте в Xcode вспомогательный iOS-проект с Product Name `Swiftgram` и собственным уникальным Organization Identifier, настройте команду разработчика. Team ID можно найти в Apple Developer либо в поле Organizational Unit сертификата Apple Development в Keychain Access. Для случайной части идентификатора upstream предлагает `openssl rand -hex 8`.
3. Сделайте локальную копию [`template_minimal_development_configuration.json`](build-system/template_minimal_development_configuration.json) вне репозитория. Сохраните остальные поля шаблона, заменив следующие значения своими:

```json
{
  "bundle_id": "<YOUR_UNIQUE_BUNDLE_ID>",
  "api_id": "<YOUR_API_ID>",
  "api_hash": "<YOUR_API_HASH>",
  "team_id": "<YOUR_TEAM_ID>"
}
```

Это фрагмент замен, а не полный конфигурационный файл. Не добавляйте конфигурацию с реальными значениями, сертификаты, профили или ключи в репозиторий, даже приватный.

### Проект Xcode

Замените все `<...>` на свои значения. Параметры и их порядок сверены с [`Make.py`](build-system/Make/Make.py); команда здесь не запускалась.

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    generateProject \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --xcodeManagedCodesigning
```

Генератор закрывает запущенный Xcode и затем открывает созданный проект. Предварительно сохраните работу в Xcode.

Имя **ReqGram** относится к приложению, но проект и target унаследованы от Swiftgram: `Telegram/Swiftgram.xcodeproj` и `//Telegram:Swiftgram`. Генератор по умолчанию использует `Telegram`; менять его на `--target=ReqGram` не нужно. В Xcode проверьте Signing & Capabilities для своей команды, выберите схему Swiftgram и устройство.

<details>
<summary><strong>Расширенная сборка, подпись и диагностика</strong></summary>

### Явное управление подписью

Вместо минимального шаблона можно скопировать [`appstore-configuration.json`](build-system/appstore-configuration.json). Каталог [`fake-codesigning`](build-system/fake-codesigning) служит образцом структуры, а не действующей подписью. Подготовьте собственные сертификаты и provisioning profiles; сверяйте entitlements с образцами в `profiles`.

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    generateProject \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --codesigningInformationPath="<LOCAL_CODESIGNING_DIRECTORY>"
```

В этом режиме iOS extensions не отключаются автоматически: для включённых targets потребуются соответствующие профили. При необходимости используйте `--disableExtensions`.

### IPA для устройства

Для распространения подготовьте distribution profiles подходящего типа и согласованную конфигурацию. Пример upstream-пути сборки, не команда получения unsigned IPA:

```sh
python3 build-system/Make/Make.py \
    --cacheDir="<BAZEL_CACHE_DIRECTORY>" \
    build \
    --configurationPath="<LOCAL_CONFIGURATION_JSON>" \
    --codesigningInformationPath="<LOCAL_CODESIGNING_DIRECTORY>" \
    --buildNumber="<BUILD_NUMBER>" \
    --configuration=release_arm64
```

Симулятору не нужна подпись для физического устройства. Upstream также документирует `generateProject --disableProvisioningProfiles`, но в текущем [`ProjectGeneration.py`](build-system/Make/ProjectGeneration.py) этот аргумент не передаётся в Bazel: не считайте его гарантированно работающим обходом профилей в этой ветке.

### Версии и частые ошибки

- Скрипт проверяет версии инструментов по `versions.json`. Глобальный `--overrideXcodeVersion` ставится **до** `build` или `generateProject`; он лишь пропускает проверку Xcode, а не обеспечивает совместимость.
- При `build-request.json not updated yet` отмените сборку в Xcode и запустите её повторно.
- При `Telegram_xcodeproj: no such package` / отсутствии BUILD в сгенерированном репозитории повторите генерацию проекта.
- Для Apple Watch есть отдельный `--embedWatchApp` в device-сборках. Для распространения нужна также действующая подпись watch-приложения; подпись основного приложения её не заменяет.

</details>

## Upstream и лицензии

ReqGram опирается на работу авторов **Telegram iOS** и **Swiftgram**; благодарность также сообществам **AyuGram** и **exteraGram**, чьи интеграции представлены в этой ветке. Имена Swiftgram, Telegram и AyuGram в исходниках сохранены там, где они относятся к унаследованным модулям и сборке.

| Проект | Ссылки |
| :--- | :--- |
| Telegram iOS | [Исходный код и руководство сборки](https://github.com/TelegramMessenger/Telegram-iOS) · [API](https://core.telegram.org/api) |
| Swiftgram | [Исходный код и руководство сборки](https://github.com/Swiftgram/Telegram-iOS) · [App Store upstream-клиента](https://apps.apple.com/app/id6471879502) |
| Сообщество Swiftgram | [Канал](https://t.me/swiftgram) · [Чат](https://t.me/swiftgramchat) · [Beta, переводы и другие ссылки](https://t.me/s/SwiftgramLinks) |
| AyuGram / exteraGram | [AyuGram](https://github.com/AyuGram) · [exteraGram](https://github.com/exteraSquad) |

Ссылки на App Store и beta относятся к **Swiftgram, не ReqGram**.

Сохраняйте copyright-уведомления и соблюдайте лицензии upstream и отдельных зависимостей. Приватность репозитория не отменяет обязательств при распространении: предоставляйте исходный код своих изменений в соответствии с применимыми лицензиями.

Требования Telegram к сторонним клиентам: используйте собственный API ID, явно обозначайте неофициальный статус, не выдавайте приложение за Telegram и не используйте стандартный логотип Telegram (белый самолётик в синем круге). Ознакомьтесь с [рекомендациями по безопасности](https://core.telegram.org/mtproto/security_guidelines) и бережно обращайтесь с данными пользователей.
