<div align="center">

# ▶︎ TubeFold

**Любое YouTube-видео → чистый Markdown-конспект.**
Работает через подписку на твой `codex` или `claude` CLI — **без API-ключей и оплаты по токенам.**

[![Release](https://img.shields.io/github/v/release/TubeFold/App?color=ff3b30&label=release&style=flat-square)](https://github.com/TubeFold/App/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/TubeFold/App/total?color=ff3b30&style=flat-square)](https://github.com/TubeFold/App/releases)
![macOS](https://img.shields.io/badge/macOS-26%2B-000?logo=apple&logoColor=white&style=flat-square)
![Swift](https://img.shields.io/badge/SwiftUI-f05138?logo=swift&logoColor=white&style=flat-square)
![Python](https://img.shields.io/badge/Python-3776ab?logo=python&logoColor=white&style=flat-square)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

```sh
brew install --cask tubefold/tap/tubefold
```

или [скачать TubeFold.zip](https://github.com/TubeFold/App/releases/latest/download/TubeFold.zip) напрямую · macOS, нотаризовано, с авто-апдейтом

</div>

---

## 💡 В чём идея

Ты уже платишь за **ChatGPT/Codex** или **Claude**. TubeFold не дёргает никакой облачный API и не просит ключ — он запускает твой **локальный CLI** (`codex` / `claude`) под капотом и забирает только финальный ответ модели. Никаких новых счетов, никакого вендор-лока.

Кидаешь ссылку на видео → получаешь структурированный Markdown, готовый лечь в заметки, Obsidian или базу знаний.

## ✨ Фишки

| | |
|---|---|
| 🔑 **Твоя подписка, а не API** | Под капотом локальный `codex` или `claude`. Модель не видит API-ключа — всё на тарифе, за который ты уже платишь. |
| 🖥 **Нативное macOS-приложение** | Нотаризованная Developer ID-сборка со встроенным Python-бэкендом. Ставится и работает из коробки. |
| 📝 **Чистый Markdown на выходе** | Транскрипт на вход → структурированный конспект с YAML front matter на выход. |
| 🔄 **Обновляется само** | Sparkle-автоапдейт держит тебя на свежей версии. Поставил и забыл. |
| 🧩 **Chrome-расширение** | Кнопка прямо на странице YouTube + подсказки «суммировать это» по истории просмотров. |
| 🌍 **Язык конспекта — любой** | Язык вывода не зависит от языка субтитров (`--language Russian`, `日本語`, что угодно). |
| 📤 **Публикация в Telegraph** | Один клик — и конспект живёт публичной статьёй со ссылкой. |
| 📊 **Учёт токенов** | Карточка Usage: токены по провайдерам, недельная квота Codex, стоимость Claude. |

## 🚀 Установка

**Рекомендуемый способ — Homebrew:**

```sh
brew install --cask tubefold/tap/tubefold
```

Дальше открой **TubeFold.app**, выбери провайдера (Codex или Claude Code) в мастере — и готово. Обновления прилетают сами через Sparkle; `brew upgrade` для них не нужен.

> **Требуется:** macOS 26+ и установленный хотя бы один CLI — [Codex](https://github.com/openai/codex) (`codex`) **или** [Claude Code](https://docs.anthropic.com/claude-code) (`claude`), залогиненный под твою подписку. Сам CLI — внешняя зависимость; в `.app` упакован только Python-бэкенд.

<details>
<summary>Альтернатива — прямое скачивание</summary>

Скачай [TubeFold.zip](https://github.com/TubeFold/App/releases/latest/download/TubeFold.zip), распакуй и перетащи `TubeFold.app` в `Applications`. Сборка подписана и нотаризована, Gatekeeper пропустит без плясок с `xattr`.

</details>

## ⚡️ Как это работает

```text
YouTube URL
  → video ID
  → метаданные (yt-dlp, опционально)
  → транскрипт (youtube-transcript-api)
  → prompt-шаблон
  → провайдер (локальный codex/claude CLI)
  → Markdown + YAML front matter
```

1. **Кидаешь ссылку** на видео.
2. TubeFold **тянет транскрипт** и оборачивает его в summary-промпт.
3. **Твоя модель крутится локально** — берётся только финальное сообщение.
4. **Получаешь Markdown-конспект** — сохраняй или делись.

> **Инвариант:** YAML front matter всегда генерирует pipeline, а не модель. Модель отвечает только за тело конспекта.

## 🎬 Использование (CLI)

Кроме приложения есть и чистый CLI:

```sh
# базовый прогон
tubefold "https://youtu.be/dQw4w9WgXcQ" --verbose

# другой провайдер и модель
tubefold "https://youtu.be/…" --provider claude --claude-model opus --claude-effort high

# язык конспекта (не зависит от языка субтитров)
tubefold "https://youtu.be/…" --language Russian

# прогнать pipeline без реальной модели (для отладки)
PROVIDER=fake tubefold "https://youtu.be/…" --verbose
```

CLI печатает абсолютный путь к созданному `.md` в stdout, диагностику — в stderr.

---

<details>
<summary><b>🛠 Для разработчиков</b> — архитектура, провайдеры, локальный API, сборка, тесты</summary>

### Архитектура

Два фронтенда над одним pipeline:

- **`bin/tubefold`** — синхронный one-shot CLI-оркестратор.
- **`bin/tubefold-server` + пакет `tubefold/`** — persistent localhost HTTP API c SQLite и фоновой очередью задач; питает Chrome-расширение и macOS-приложение.

Оба переиспользуют хелперы из `scripts/tubefold_lib.py` (парсинг URL, извлечение метаданных, front matter, безопасные имена файлов).

### Провайдеры

Провайдер — исполняемый файл `providers/<name>.sh`, вызывается как:

```sh
provider <prompt_file> <output_file>
```

Он должен записать в `<output_file>` **только** финальный Markdown и вернуть `0`.

- `providers/codex.sh` — `codex exec` из изолированного temp-каталога (`--sandbox read-only --ephemeral`), промпт через stdin, ответ через `--output-last-message`.
- `providers/claude.sh` — `claude --print --output-format json`, промпт через stdin; подписка пользователя (OAuth/keychain), не API-ключ.
- `providers/fake.sh` — канонические заглушки для тестов.

Оба first-class провайдера best-effort пишут token usage в сайдкар `<output_file>.usage.json`.

### Установка из исходников

```sh
python3 -m pip install -r requirements.txt
./install.sh   # проверит deps, создаст ~/.config/tubefold/config.env, слинкует CLI в ~/.local/bin
```

### Конфигурация

Приоритет: CLI-флаги → env vars → `~/.config/tubefold/config.env` → дефолты. Пример — в `config/config.example.env`.

```sh
PROVIDER="codex"                  # или "claude"
OUTPUT_DIR="$HOME/Documents/YouTube Summaries"
PROMPT_TEMPLATE="detailed-summary.md"
OUTPUT_LANGUAGE="English"         # подставляется в шаблон как {{OUTPUT_LANGUAGE}}
PREFERRED_TRANSCRIPT_LANGS="pl,ru,en"
ALLOW_ANY_TRANSCRIPT_LANGUAGE="true"
CODEX_MODEL="gpt-5.4-mini"        # CODEX_REASONING_EFFORT, CODEX_TIMEOUT_SECONDS
CLAUDE_MODEL="sonnet"             # alias или полный id; CLAUDE_REASONING_EFFORT: low…max
LOG_LEVEL="info"
```

### Output Markdown

Итоговый файл получает YAML front matter (`type`, `source`, `video_id`, `url`, `title`, `channel`, `duration_seconds`, `published_at`, `processed_at`, `transcript_language*`, `provider`, `prompt_template`). Имена файлов строятся из названия видео, чистятся для macOS и не перезаписывают существующие (` (2)`, ` (3)`…).

### Локальный API

```sh
tubefold-server --provider codex      # или --provider fake для отладки без модели
```

Слушает только `127.0.0.1:43821`. Опциональная bearer-авторизация через `TUBEFOLD_API_TOKEN`. Основные эндпоинты:

```text
GET    /health
POST   /api/v1/summaries
GET    /api/v1/jobs/{jobId}
GET    /api/v1/videos                          # библиотека (+ readingTimeMinutes)
DELETE /api/v1/videos/{videoId}
POST   /api/v1/videos/{videoId}/regenerate
POST   /api/v1/videos/{videoId}/publish-telegraph
GET    /api/v1/usage                           # агрегированная статистика токенов
POST   /api/v1/provider-setup/select           # {"provider":"codex"|"claude"}
POST   /api/v1/provider-setup/{codex|claude}/{detect,test,model}
POST   /api/v1/provider-setup/{complete,output-language}
POST   /api/v1/watch-activity[/dismiss]
```

### macOS-приложение

Xcode-проект — `TubeFold App/TubeFold.xcodeproj`. Build phase `Embed Python Backend` упаковывает в `.app` весь бэкенд + Python-framework + зависимости, ad-hoc подписывает и валидирует импорты на этапе сборки. В рантайме `BackendProcessController` сам поднимает и супервизит embedded `tubefold-server`; `/health` работает как gate совместимости клиента и бэкенда.

```sh
xcodebuild -project "TubeFold App/TubeFold.xcodeproj" \
  -scheme TubeFold -configuration Debug -destination "platform=macOS" build
```

### Авто-апдейт (Sparkle)

Приложение ships [Sparkle 2](https://sparkle-project.org). `SUFeedURL` → `releases/latest/download/appcast.xml`, апдейты подписаны EdDSA. Релиз автоматизирован — см. ниже.

### Релиз (CI)

Пуш тега `v<MARKETING_VERSION>` запускает `.github/workflows/release.yml`: build → sign → notarize → staple → zip → EdDSA-appcast → GitHub Release → bump каски в `TubeFold/homebrew-tap`. Локально весь цикл воспроизводится через `scripts/release-macos.sh` + `scripts/generate-appcast.sh`.

```sh
git tag v0.3 && git push origin v0.3   # должно равняться MARKETING_VERSION
```

### Тесты

```sh
python3 -m unittest discover -s tests
```

~90 тестов: парсинг URL, выбор языка транскрипта, безопасные имена, Telegraph/reading-time, usage-сайдкары и end-to-end pipeline с fake-провайдером. Реальные Codex/Claude в автотестах не вызываются.

### Hammerspoon (опционально)

Хоткей `Option+Cmd+Y` суммирует видео из активной вкладки браузера (Safari/Chrome/Arc/Brave/Edge) без открытия терминала — см. `hammerspoon/tubefold.lua`.

</details>

<details>
<summary><b>🧯 Частые ошибки</b></summary>

| Сообщение | Решение |
|---|---|
| `Missing dependency: youtube-transcript-api` | `python3 -m pip install youtube-transcript-api` |
| `Missing dependency: codex` | Поставь Codex CLI, проверь `codex --help` |
| `authorization/login problem` | `codex login` (или `claude` login) и повтори |
| `No transcript found` | Нет субтитров для настроенных языков → включи `ALLOW_ANY_TRANSCRIPT_LANGUAGE=true` |

</details>

## 🗺 Roadmap

- [x] Нотаризованная упаковка + Homebrew + авто-апдейт
- [ ] Chunked summarization для длинных видео
- [ ] Whisper fallback при отсутствии субтитров
- [ ] Несколько prompt-шаблонов
- [ ] Obsidian URI / vault integration

> **MVP-ограничения:** нет плейлистов, нет Whisper, длинные транскрипты пока отправляются целиком.

## 📄 Лицензия

[MIT](LICENSE) © 2026 Bogdan Bystritskiy

<div align="center">
<sub><a href="https://github.com/TubeFold">github.com/TubeFold</a> · собрано вне Mac App Store, подписано и нотаризовано Developer ID</sub>
</div>
