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
MAX_TRANSCRIPT_CHARACTERS="150000"
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

`Transcript is too large`
: MVP пока не делает chunked summarization. Увеличьте `MAX_TRANSCRIPT_CHARACTERS` или дождитесь реализации chunking.

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
