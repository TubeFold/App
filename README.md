<div align="center">

# ▶︎ TubeFold

**Любое YouTube-видео → чистый Markdown-конспект.**
Работает через подписку на твой `codex` или `claude` CLI — **без API-ключей и оплаты по токенам.**

[![Release](https://img.shields.io/github/v/release/TubeFold/App?color=ff3b30&label=release&style=flat-square)](https://github.com/TubeFold/App/releases/latest)
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
| 📝 **Чистый Markdown на выходе** | Транскрипт на вход → структурированный конспект на выход. |
| 🧩 **Chrome-расширение** | Кнопка прямо на странице YouTube + подсказки «суммировать это» по истории просмотров. |
| 📤 **Публикация в Telegraph** | Один клик — и конспект живёт публичной статьёй со ссылкой. |

## 🚀 Установка

```sh
brew install --cask tubefold/tap/tubefold
```

## ⚡️ Как это работает

```text
YouTube URL
  → video ID
  → метаданные (yt-dlp)
  → транскрипт (youtube-transcript-api)
  → prompt-шаблон
  → провайдер (локальный codex/claude)
  → готовое Markdown саммари
```

## 🗺 Roadmap

- [x] Нотаризованная упаковка + Homebrew + авто-апдейт
- [ ] Несколько prompt-шаблонов (например отдельный шаблон для Anki)
- [ ] Obsidian integration

## 📄 Лицензия

[MIT](LICENSE)