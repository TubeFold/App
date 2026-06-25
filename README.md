# youtube-summary

macOS CLI-инструмент для создания Markdown-саммари YouTube-видео через пользовательскую подписку и Codex CLI. OpenAI API не используется: основной provider запускает `codex exec` локально и забирает только финальное сообщение модели.

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

- `bin/youtube-summary` - CLI orchestrator.
- `providers/codex.sh` - Codex CLI provider.
- `providers/fake.sh` - test/development provider without Codex.
- `prompts/detailed-summary.md` - prompt template.
- `scripts/fetch-transcript.py` - transcript fetching through `youtube-transcript-api`.
- `hammerspoon/youtube-summary.lua` - optional hotkey integration.

Provider contract:

```bash
provider <prompt_file> <output_file>
```

Provider должен записать в `output_file` только финальный Markdown-ответ модели и вернуть `0` при успехе.

## Требования

- macOS.
- `python3`.
- `youtube-transcript-api`.
- Codex CLI (`codex`) для provider `codex`.
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

## Установка

Python-зависимость:

```bash
python3 -m pip install -r requirements.txt
```

```bash
./install.sh
```

Скрипт:

- проверит `python3`, `youtube-transcript-api`, `codex`;
- создаст `~/.config/youtube-summary/config.env`, если его еще нет;
- сделает скрипты исполняемыми;
- создаст symlink `~/.local/bin/youtube-summary`.

Если `~/.local/bin` не в `PATH`, добавьте его в shell profile.

## Конфигурация

Пример находится в `config/config.example.env`.

Пользовательский конфиг по умолчанию:

```text
~/.config/youtube-summary/config.env
```

Приоритет настроек:

1. CLI-аргументы.
2. Environment variables.
3. Пользовательский config.
4. Значения по умолчанию.

Ключевые параметры:

```bash
PROVIDER="codex"
OUTPUT_DIR="$HOME/Documents/YouTube Summaries"
PROMPT_TEMPLATE="detailed-summary.md"
PREFERRED_TRANSCRIPT_LANGS="pl,ru,en"
ALLOW_ANY_TRANSCRIPT_LANGUAGE="true"
OPEN_AFTER_SAVE="false"
CODEX_TIMEOUT_SECONDS="900"
LOG_LEVEL="info"
```

## Ручной запуск

```bash
youtube-summary "https://youtu.be/dQw4w9WgXcQ" --verbose
```

Для проверки pipeline без Codex:

```bash
PROVIDER=fake youtube-summary "https://youtu.be/dQw4w9WgXcQ" --verbose
```

CLI печатает абсолютный путь к созданному `.md` в stdout. Диагностика идет в stderr.

Полезные параметры:

```bash
youtube-summary --help
youtube-summary "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --output-dir "$HOME/Desktop/Summaries"
youtube-summary "https://youtu.be/dQw4w9WgXcQ" --keep-temp --verbose
youtube-summary "https://youtu.be/dQw4w9WgXcQ" --provider fake
```

## Output Markdown

Итоговый файл получает YAML front matter, который создает pipeline, а не модель:

```yaml
---
type: "youtube-summary"
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
dofile("/Users/bogdan/GIT/youtube-summary/hammerspoon/youtube-summary.lua")
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

Если Hammerspoon не видит `youtube-summary`, задайте абсолютный путь:

```lua
package.loaded["youtube-summary"] = nil
local ys = dofile("/Users/bogdan/GIT/youtube-summary/hammerspoon/youtube-summary.lua")
ys.cliPath = "/Users/bogdan/.local/bin/youtube-summary"
```

macOS может запросить Automation/Accessibility permissions для Hammerspoon, Safari или Chrome.

## YouTube Brain Local API

Дополнительно к CLI в проекте есть development-прототип YouTube Brain: localhost API + Chrome Extension. macOS-приложение включает копию backend-а внутри `.app` и поднимает этот helper само; ручной запуск нужен только для отладки API или extension. Helper переиспользует тот же transcript/Codex pipeline, но сохраняет данные в:

```text
~/Library/Application Support/YouTube Brain/
```

Ручной запуск сервера для development-отладки:

```bash
youtube-brain-server --provider codex
```

Для проверки без Codex:

```bash
youtube-brain-server --provider fake
```

Endpoints:

```text
GET  http://127.0.0.1:43821/health
GET  http://127.0.0.1:43821/api/v1/provider-setup
POST http://127.0.0.1:43821/api/v1/provider-setup/codex/detect
POST http://127.0.0.1:43821/api/v1/provider-setup/codex/test
POST http://127.0.0.1:43821/api/v1/provider-setup/complete
POST http://127.0.0.1:43821/api/v1/summaries
GET  http://127.0.0.1:43821/api/v1/jobs/{jobId}
GET  http://127.0.0.1:43821/api/v1/videos/by-youtube-id/{youtubeVideoId}
POST http://127.0.0.1:43821/api/v1/videos/{videoId}/regenerate
```

Provider setup endpoints implement the backend for the Codex onboarding wizard:

```bash
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/codex/detect
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/codex/test
curl -sS -X POST http://127.0.0.1:43821/api/v1/provider-setup/complete
```

Detection checks saved path, login-shell `command -v codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, and `~/.local/bin/codex`. The connection test runs Codex from an isolated temp directory with a marker prompt and stores only setup state, not credentials or the full test output.

## YouTube Brain macOS App

Xcode-проект находится в:

```text
Youtube Brain App/Youtube Brain App.xcodeproj
```

Текущий SwiftUI app реализует MVP onboarding для Codex:

- стартовый экран состояния приложения без ручных backend-команд;
- wizard `Before you begin -> Check installation -> Test connection -> Complete`;
- автоматический запуск и остановку local helper;
- embedded backend в `Contents/Resources/YouTubeBrainBackend`;
- автоматический поиск `codex`;
- ручной выбор executable;
- connection test через `POST /api/v1/provider-setup/codex/test`;
- сохранение завершённого setup через `POST /api/v1/provider-setup/complete`.
- главный экран Codex status: `Installed`, `Signed in`, `Ready`;
- repair flow: если сохранённый Codex путь сломан или connection test больше не проходит, setup помечается incomplete и app открывает нужный шаг wizard.

Перед запуском app вручную поднимать `youtube-brain-server` не нужно. Xcode build phase `Embed Python Backend` копирует в app bundle `bin/`, `youtube_brain/`, `scripts/`, `providers/`, `prompts/`, `config/`, `requirements.txt`, Python framework, interpreter и Python dependencies. Для текущей direct-distribution сборки App Sandbox выключен, потому что приложение запускает локальный helper-процесс и может использовать выбранный пользователем Codex executable после перезапуска.

Build phase проверяет embedded backend прямо во время сборки:

```text
Youtube Brain.app/Contents/Resources/YouTubeBrainBackend/
  Runtime/Python.framework/
  Runtime/bin/python3
  Runtime/lib/python*/site-packages/
  youtube-brain-server
```

Для сборки из терминала:

```bash
xcodebuild -project "Youtube Brain App/Youtube Brain App.xcodeproj" -scheme "Youtube Brain" -configuration Debug -destination "platform=macOS" build
```

Сервер слушает только `127.0.0.1`. Для development API token по умолчанию отключён. Чтобы включить локальную авторизацию:

```bash
export YOUTUBE_BRAIN_API_TOKEN="dev-local-token"
```

Логи:

```text
~/Library/Application Support/YouTube Brain/logs/app.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/job.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/metadata.stdout.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/metadata.stderr.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/transcript.stdout.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/transcript.stderr.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/provider-codex.stdout.log
~/Library/Application Support/YouTube Brain/jobs/<job-id>/provider-codex.stderr.log
```

`app.log` содержит HTTP-запросы, dedupe-решения, переходы статусов, запуск процессов, exit codes, длительность и размеры. `job.log` содержит компактный timeline конкретной задачи. Полный transcript и summary в эти логи не пишутся.

Chrome Extension находится в `chrome-extension/`. Установка development build:

1. Откройте `chrome://extensions`.
2. Включите Developer Mode.
3. Нажмите Load unpacked.
4. Выберите `/Users/bogdan/GIT/youtube-summary/chrome-extension`.
5. Откройте macOS-приложение YouTube Brain или вручную запустите `youtube-brain-server` для чистой API-отладки.
6. Откройте YouTube-видео и нажмите иконку YouTube Brain.

Это ещё не финальная notarized упаковка. Сейчас macOS app уже прячет ручной запуск backend-а, управляет helper-ом и включает backend-код с Python runtime в `.app`; установленный Codex CLI пока остаётся внешней зависимостью пользователя.

## Тесты

```bash
python3 -m unittest discover -s tests
```

Тесты покрывают разбор YouTube URL, выбор transcript language, объединение `snippet.text`, безопасные имена файлов и end-to-end pipeline с fake provider. Настоящий Codex в автоматических тестах не вызывается.

Manual smoke test с Codex:

```bash
youtube-summary "https://youtu.be/dQw4w9WgXcQ" --verbose
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
