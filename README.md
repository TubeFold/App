# tubefold

macOS CLI-инструмент для создания Markdown-саммари YouTube-видео через пользовательскую подписку и CLI модели. HTTP API модели не используется: provider запускает CLI локально и забирает только финальное сообщение модели. Поддерживаются два провайдера на выбор: `codex` (`codex exec`, по умолчанию) и `claude` (Claude Code CLI, `claude --print`) — оба работают по подписке пользователя, без API-ключа.

## Архитектура

Pipeline:

```text
YouTube URL
-> parse video ID
-> optional yt-dlp metadata
-> youtube-transcript-api transcript
-> plain transcript text
-> prompt template
-> provider <prompt_file> <output_file>
-> Markdown with front matter
```

Главные части:

- `bin/tubefold` - CLI orchestrator.
- `providers/codex.sh` - Codex CLI provider.
- `providers/claude.sh` - Claude Code CLI provider (`claude --print`).
- `providers/fake.sh` - test/development provider without a real CLI.
- `prompts/detailed-summary.md` - prompt template.
- `scripts/fetch-transcript.py` - transcript fetching through `youtube-transcript-api`.
- `hammerspoon/tubefold.lua` - optional hotkey integration.

Provider contract:

```bash
provider <prompt_file> <output_file>
```

Provider должен записать в `output_file` только финальный Markdown-ответ модели и вернуть `0` при успехе.

## Требования

- macOS.
- `python3`.
- `youtube-transcript-api`.
- Codex CLI (`codex`) для provider `codex` **или** Claude Code CLI (`claude`) для provider `claude` (нужен хотя бы один).
- `yt-dlp` опционально для метаданных.
- Hammerspoon только для горячей клавиши.
- `ffmpeg` может понадобиться `yt-dlp` в некоторых окружениях, но видео в MVP не скачивается.

Проверка:

```bash
command -v python3
command -v codex
python3 -c 'import youtube_transcript_api'
codex exec --help
```

Текущая реализация Codex provider использует:

```bash
codex exec \
  --sandbox read-only \
  --cd "$isolated_temp_dir" \
  --skip-git-repo-check \
  --ephemeral \
  --ignore-rules \
  --output-last-message "$output_file" \
  -
```

Промпт передается через stdin. Codex запускается из отдельной временной директории.

Provider `claude` запускает:

```bash
claude --print \
  --model "$CLAUDE_MODEL" \
  --effort "$CLAUDE_REASONING_EFFORT" \
  --output-format text
```

Промпт передается через stdin, ответ забирается из stdout. `claude` запускается из отдельной временной директории (чтобы CLI не подхватил `CLAUDE.md` из репозитория) и использует подписку пользователя (OAuth/keychain), а не API-ключ.

## Установка

Python-зависимость:

```bash
python3 -m pip install -r requirements.txt
```

```bash
./install.sh
```

Скрипт:

- проверит `python3`, `youtube-transcript-api` и наличие хотя бы одного CLI провайдера (`codex` или `claude`);
- создаст `~/.config/tubefold/config.env`, если его еще нет;
- сделает скрипты исполняемыми;
- создаст symlink `~/.local/bin/tubefold`.

Если `~/.local/bin` не в `PATH`, добавьте его в shell profile.

## Конфигурация

Пример находится в `config/config.example.env`.

Пользовательский конфиг по умолчанию:

```text
~/.config/tubefold/config.env
```

Приоритет настроек:

1. CLI-аргументы.
2. Environment variables.
3. Пользовательский config.
4. Значения по умолчанию.

Ключевые параметры:

```bash
PROVIDER="codex"            # или "claude"
OUTPUT_DIR="$HOME/Documents/YouTube Summaries"
PROMPT_TEMPLATE="detailed-summary.md"
PREFERRED_TRANSCRIPT_LANGS="pl,ru,en"
ALLOW_ANY_TRANSCRIPT_LANGUAGE="true"
OPEN_AFTER_SAVE="false"
CODEX_TIMEOUT_SECONDS="900"
CODEX_MODEL="gpt-5.4-mini"
CODEX_REASONING_EFFORT="medium"
CLAUDE_TIMEOUT_SECONDS="900"
CLAUDE_MODEL="sonnet"       # alias (sonnet, opus, haiku) или полный id
CLAUDE_REASONING_EFFORT="medium"  # low, medium, high, xhigh, max
LOG_LEVEL="info"
```

Запуск через Claude Code CLI:

```bash
tubefold "https://youtu.be/dQw4w9WgXcQ" --provider claude --claude-model opus --claude-effort high
```

## Ручной запуск

```bash
tubefold "https://youtu.be/dQw4w9WgXcQ" --verbose
```

Для проверки pipeline без Codex:

```bash
PROVIDER=fake tubefold "https://youtu.be/dQw4w9WgXcQ" --verbose
```

CLI печатает абсолютный путь к созданному `.md` в stdout. Диагностика идет в stderr.

Полезные параметры:

```bash
tubefold --help
tubefold "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --output-dir "$HOME/Desktop/Summaries"
tubefold "https://youtu.be/dQw4w9WgXcQ" --keep-temp --verbose
tubefold "https://youtu.be/dQw4w9WgXcQ" --provider fake
```

## Output Markdown

Итоговый файл получает YAML front matter, который создает pipeline, а не модель:

```yaml
---
type: "tubefold"
source: "youtube"
video_id: "..."
url: "https://www.youtube.com/watch?v=..."
title: "..."
channel: "..."
duration_seconds: 1234
published_at: "2026-06-20"
processed_at: "2026-06-25T12:30:00+02:00"
subtitle_language: "en"
transcript_language: "English"
transcript_language_code: "en"
transcript_is_generated: true
provider: "codex"
prompt_template: "detailed-summary"
---
```

Имена файлов строятся из названия видео, очищаются для macOS и не перезаписывают существующие файлы. При конфликте добавляется суффикс `(2)`, `(3)` и так далее.

## Hammerspoon

Подключите скрипт из `~/.hammerspoon/init.lua`:

```lua
dofile("/Users/bogdan/GIT/tubefold/hammerspoon/tubefold.lua")
```

По умолчанию hotkey:

```text
Option + Command + Y
```

Поддерживаемые браузеры:

- Safari;
- Google Chrome;
- Arc;
- Brave Browser;
- Microsoft Edge.

Скрипт получает URL активной вкладки через AppleScript и запускает CLI через `hs.task`, не открывая Terminal. Повторный запуск блокируется, пока текущая задача не завершится.

Если Hammerspoon не видит `tubefold`, задайте абсолютный путь:

```lua
package.loaded["tubefold"] = nil
local ys = dofile("/Users/bogdan/GIT/tubefold/hammerspoon/tubefold.lua")
ys.cliPath = "/Users/bogdan/.local/bin/tubefold"
```

macOS может запросить Automation/Accessibility permissions для Hammerspoon, Safari или Chrome.

## TubeFold Local API

Дополнительно к CLI в проекте есть development-прототип TubeFold: localhost API + Chrome Extension. macOS-приложение включает копию backend-а внутри `.app` и поднимает этот helper само; ручной запуск нужен только для отладки API или extension. Helper переиспользует тот же transcript/Codex pipeline, но сохраняет данные в:

```text
~/Library/Application Support/TubeFold/
```

Ручной запуск сервера для development-отладки:

```bash
tubefold-server --provider codex
```

Для проверки без Codex:

```bash
tubefold-server --provider fake
```

Endpoints:

```text
GET  http://127.0.0.1:43821/health
GET  http://127.0.0.1:43821/api/v1/provider-setup
POST http://127.0.0.1:43821/api/v1/provider-setup/select            # {"provider":"codex"|"claude"}
POST http://127.0.0.1:43821/api/v1/provider-setup/{codex|claude}/detect
POST http://127.0.0.1:43821/api/v1/provider-setup/{codex|claude}/test
POST http://127.0.0.1:43821/api/v1/provider-setup/{codex|claude}/model
POST http://127.0.0.1:43821/api/v1/provider-setup/complete
POST http://127.0.0.1:43821/api/v1/summaries
GET  http://127.0.0.1:43821/api/v1/jobs/{jobId}
GET  http://127.0.0.1:43821/api/v1/videos/by-youtube-id/{youtubeVideoId}
POST http://127.0.0.1:43821/api/v1/videos/{videoId}/regenerate
```

Provider setup endpoints implement the backend for the onboarding wizard (`{provider}` is `codex` or `claude`):

```bash
curl -sS -X POST -H 'Content-Type: application/json' -d '{"provider":"claude"}' \
  http://127.0.0.1:43821/api/v1/provider-setup/select
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/claude/detect
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/claude/test
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/complete
```

Detection checks the saved path, login-shell `command -v <binary>`, and the usual Homebrew/`~/.local/bin` locations for the chosen provider (`codex` or `claude`). The connection test runs the provider from an isolated temp directory with a marker prompt and stores only setup state, not credentials or the full test output. The embedded server boots with `--provider codex`, but the active provider is whichever the user selected in-app (`selectedProviderID` in `provider-setup.json`) — no relaunch needed to switch.

## TubeFold macOS App

Xcode-проект находится в:

```text
TubeFold App/TubeFold.xcodeproj
```

Текущий SwiftUI app реализует onboarding для выбранного провайдера (Codex или Claude Code, переключатель в мастере и в настройках):

- стартовый экран состояния приложения без ручных backend-команд;
- wizard `Before you begin -> Check installation -> Test connection -> Complete`;
- автоматический запуск и остановку local helper;
- embedded backend в `Contents/Resources/TubeFoldBackend`;
- выбор провайдера (Codex / Claude Code) на первом шаге wizard и в настройках;
- автоматический поиск бинарника выбранного провайдера (`codex` или `claude`);
- ручной выбор executable;
- connection test через `POST /api/v1/provider-setup/{codex|claude}/test`;
- сохранение завершённого setup через `POST /api/v1/provider-setup/complete`.
- главный экран статуса провайдера: `Installed`, `Signed in`, `Ready`;
- repair flow: если сохранённый путь провайдера сломан или connection test больше не проходит, setup помечается incomplete и app открывает нужный шаг wizard.

Перед запуском app вручную поднимать `tubefold-server` не нужно. Xcode build phase `Embed Python Backend` копирует в app bundle `bin/`, `tubefold/`, `scripts/`, `providers/`, `prompts/`, `config/`, `requirements.txt`, Python framework, interpreter и Python dependencies. Для текущей direct-distribution сборки App Sandbox выключен, потому что приложение запускает локальный helper-процесс и может использовать выбранный пользователем Codex executable после перезапуска.

Build phase проверяет embedded backend прямо во время сборки:

```text
TubeFold.app/Contents/Resources/TubeFoldBackend/
  Runtime/Python.framework/
  Runtime/bin/python3
  Runtime/lib/python*/site-packages/
  tubefold-server
```

Для сборки из терминала:

```bash
xcodebuild -project "TubeFold App/TubeFold.xcodeproj" -scheme "TubeFold" -configuration Debug -destination "platform=macOS" build
```

Сервер слушает только `127.0.0.1`. Для development API token по умолчанию отключён. Чтобы включить локальную авторизацию:

```bash
export TUBEFOLD_API_TOKEN="dev-local-token"
```

Логи:

```text
~/Library/Application Support/TubeFold/logs/app.log
~/Library/Application Support/TubeFold/jobs/<job-id>/job.log
~/Library/Application Support/TubeFold/jobs/<job-id>/metadata.stdout.log
~/Library/Application Support/TubeFold/jobs/<job-id>/metadata.stderr.log
~/Library/Application Support/TubeFold/jobs/<job-id>/transcript.stdout.log
~/Library/Application Support/TubeFold/jobs/<job-id>/transcript.stderr.log
~/Library/Application Support/TubeFold/jobs/<job-id>/provider-codex.stdout.log
~/Library/Application Support/TubeFold/jobs/<job-id>/provider-codex.stderr.log
```

`app.log` содержит HTTP-запросы, dedupe-решения, переходы статусов, запуск процессов, exit codes, длительность и размеры. `job.log` содержит компактный timeline конкретной задачи. Полный transcript и summary в эти логи не пишутся.

Chrome Extension находится в `chrome-extension/`. Установка development build:

1. Откройте `chrome://extensions`.
2. Включите Developer Mode.
3. Нажмите Load unpacked.
4. Выберите `/Users/bogdan/GIT/tubefold/chrome-extension`.
5. Откройте macOS-приложение TubeFold или вручную запустите `tubefold-server` для чистой API-отладки.
6. Откройте YouTube-видео и нажмите иконку TubeFold.

Это ещё не финальная notarized упаковка. Сейчас macOS app уже прячет ручной запуск backend-а, управляет helper-ом и включает backend-код с Python runtime в `.app`; установленный Codex CLI пока остаётся внешней зависимостью пользователя.

## Тесты

```bash
python3 -m unittest discover -s tests
```

Тесты покрывают разбор YouTube URL, выбор transcript language, объединение `snippet.text`, безопасные имена файлов и end-to-end pipeline с fake provider. Настоящий Codex в автоматических тестах не вызывается.

Manual smoke test с Codex:

```bash
tubefold "https://youtu.be/dQw4w9WgXcQ" --verbose
```

Критерии:

- exit code `0`;
- stdout содержит путь к Markdown;
- front matter заполнен;
- output не содержит служебный вывод Codex;
- временные файлы удалены, если не указан `--keep-temp`.

## Частые ошибки

`Missing dependency: youtube-transcript-api`
: Установите Python-библиотеку: `python3 -m pip install youtube-transcript-api`.

`Missing dependency: codex`
: Установите Codex CLI и проверьте `codex --help`.

`authorization/login problem`
: Выполните `codex login` и повторите запуск.

`No transcript found`
: У видео нет доступного transcript для настроенных языков. Можно включить `ALLOW_ANY_TRANSCRIPT_LANGUAGE=true`.


## Ограничения MVP

- Не обрабатываются плейлисты.
- Нет Whisper fallback.
- Нет OpenAI API provider.
- Нет Claude Code provider.
- Нет GUI-приложения.
- Нет очереди задач.
- Chunked summarization пока не реализован.

## Будущее развитие

- `providers/claude-code.sh`.
- ChatGPT Desktop provider через UI automation.
- Chunked summarization для длинных видео.
- Whisper fallback при отсутствии субтитров.
- Несколько prompt templates.
- Obsidian URI/vault integration.
- История обработанных видео и дедупликация.
