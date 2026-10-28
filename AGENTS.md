# AGENTS.md — ListenAndRecord: описание проекта для ИИ-ассистентов

Этот файл — полный «ввод в курс дела» для нейросети (Codex, ChatGPT, Claude и др.), которая продолжает разработку.
Читай его целиком перед любыми изменениями. **Общайся с владельцем проекта по-русски**, простым языком: он не программист,
собирает и запускает программу сам по твоим инструкциям.

---

## 1. Что это за программа

**ListenAndRecord** — настольное приложение для записи видеозвонков и локальной (офлайн) расшифровки речи.
Две независимые реализации с одинаковой функциональностью:

| | macOS | Windows |
|---|---|---|
| Папка | `Sources/ListenAndRecord/` | `windows/ListenAndRecord/` |
| Язык / UI | Swift 5 (режим языка 5), SwiftUI | C# 12, .NET 8, WPF |
| Минимальная ОС | macOS 14, Apple Silicon (у владельца MacBook Air M3) | Windows 10/11 x64 |
| Распознаватель | whisper.cpp v1.9.2 как `whisper.xcframework` (Metal), вызов через C API | whisper.cpp v1.9.2, собственная сборка `whisper-cli.exe` + DLL, запуск подпроцессом |
| Захват звука | ScreenCaptureKit (системный звук) + AVAudioEngine (микрофон) | NAudio 2.2.1: WASAPI loopback + WasapiCapture |

Функции (обе платформы):
- Запись **всех участников созвона**: системный звук (голоса собеседников из Zoom/Meet/Teams/Telegram и т.д.) + микрофон
  пишутся в две дорожки, синхронизируются по общим часам, при сохранении сводятся в один файл.
- Кнопки **Старт / Пауза / Продолжить / Стоп**. Mac: окно, иконка в строке меню, ⌘R / ⇧⌘P / ⌘. .
  Windows: окно + глобальные горячие клавиши Ctrl+Alt+R / Ctrl+Alt+P / Ctrl+Alt+S.
- Сохранение: ввод имени файла, выбор папки (системный диалог), форматы **M4A (AAC 128k), MP3 (128k), WAV (16 бит)**, моно 48 кГц,
  с нормализацией громкости (пик ≈ −1 dBFS).
- Восстановление несохранённой записи после сбоя/закрытия.
- **Расшифровка** любого аудио/видео в **TXT или DOCX** (DOCX генерируется вручную, без библиотек), по желанию с метками [чч:мм:сс].
- **Менеджер моделей** внутри приложения: скачать/удалить/выбрать модель Whisper, добавить свой файл `ggml-*.bin`,
  рекомендация модели под железо. Модели качаются с `huggingface.co/ggerganov/whisper.cpp`, Silero VAD — с `huggingface.co/ggml-org/whisper-vad`.
- Всё распознавание локально, без интернета и подписок (интернет — только для однократного скачивания модели).

Целевое железо владельца:
- MacBook Air M3 → модель Large v3 Turbo (`ggml-large-v3-turbo.bin`), beam search 5.
- ПК Ryzen 5 5600H, 16 ГБ, Windows 11/10 → `ggml-large-v3-turbo-q5_0.bin`.
- Старый ПК Core i5-760 (2010 г., **нет AVX/AVX2**, только SSE4.2), 4 ГБ ОЗУ, GeForce 210, Windows 10 → `ggml-small.bin`, greedy.

---

## 2. Состояние текущей ревизии

- Репозиторий: `https://github.com/GrigoriyUchaev/ListenAndRecord`, рабочая ветка **`claude/mac-call-recording-app-ok2rkp`**
  (ветки `main` пока нет — это единственная ветка). Последний проверенный коммит: `e923c6c`.
- CI (GitHub Actions, `.github/workflows/build.yml`) **зелёный** на обеих платформах: сборка + самотест расшифровки.
- Готовые сборки — артефакты CI: `ListenAndRecord-macOS` (ZIP GitHub с `ListenAndRecord.dmg` внутри), `ListenAndRecord-Windows`
  (`ListenAndRecord-Setup.exe` — установщик Inno Setup без прав администратора, и portable zip).

**Что проверено автоматически:**
- обе версии компилируются;
- встроенный whisper реально распознаёт речь (Mac — через C API, Windows — через `whisper-cli.exe`);
- тестовая запись «фраза + 25 с тишины + фраза + 40 с шума + фраза» расшифровывается целиком и с верными таймкодами;
- Windows-движок работает на коде SSE4.2 (имитация i5-760).

**Что НЕ проверено (владелец ещё не тестировал на живых машинах):**
- интерфейс обеих версий вживую, захват звука, разрешения macOS (микрофон, «Запись экрана и системного звука»);
- WASAPI-запись на Windows, кодирование M4A/MP3 через Media Foundation, глобальные горячие клавиши;
- скачивание моделей внутри приложения;
- работа на i5-760 / 4 ГБ (скорость, память).
Первая сборка Mac-версии v1 (с внешним whisper-cli) у владельца собиралась и запускалась; версия 2 (встроенный whisper) — ещё нет.

---

## 3. Структура репозитория

```
Package.swift                      SwiftPM: executableTarget + binaryTarget "whisper" (xcframework v1.9.2, URL+checksum)
Resources/Info.plist, AppIcon.*    plist .app (иконка, NSMicrophoneUsageDescription и др.)
scripts/build_app.sh               сборка ListenAndRecord.app (swift build → бандл → whisper.framework в Contents/Frameworks → rpath → ad-hoc codesign)
scripts/package-macos.sh           образ ListenAndRecord.dmg с приложением и ярлыком Applications
tests/check_macos_package.sh       монтирует DMG, копирует приложение, проверяет подпись и запуск/выход после расшифровки
scripts/build-whisper-windows.ps1  сборка whisper.cpp под Windows (MSVC, все CPU-варианты) → windows/ListenAndRecord/whisper/
tests/make_pause_sample.py         делает тестовый WAV с длинными паузами из samples/jfk.wav
tests/check_transcript.py          проверяет, что все 3 повтора фразы распознаны
Design/                            исходники иконки (SVG «красный мегафон»), PNG
.github/workflows/build.yml        CI: jobs macos (macos-15) и windows (windows-2022)

Sources/ListenAndRecord/
  App/ListenAndRecordApp.swift     @main: Window + MenuBarExtra, меню «Запись», AppDelegate (подтверждение выхода)
  App/AppSettings.swift            настройки (UserDefaults), список языков
  App/ModelManager.swift           каталог моделей, скачивание (URLSessionDownloadDelegate), импорт, поиск моделей на диске (mdfind)
  App/TranscriptionController.swift  запуск расшифровки, кэш загруженной модели (WhisperEngine), сохранение TXT/DOCX
  App/SelfTest.swift               скрытый режим `--selftest <model> <audio>` для CI
  Recording/CaptureSession.swift   ScreenCaptureKit (аудио) + AVAudioEngine (микрофон), перезапуск при смене устройства
  Recording/RecordingClock.swift   общие часы записи с учётом пауз
  Recording/TrackWriter.swift      запись дорожки в CAF 48 кГц моно float с выравниванием по времени
  Recording/CallRecorder.swift     состояние записи для UI, сохранение, восстановление несохранённого
  Recording/AudioExporter.swift    сведение дорожек, M4A/WAV через AVAudioFile, MP3 через внешний lame/ffmpeg (если установлен)
  Transcription/WhisperEngine.swift   обёртка над C API whisper.cpp (whisper_full и т.д.), отмена через abort_callback
  Transcription/TranscriptionPipeline.swift  весь конвейер расшифровки (см. раздел 4)
  Transcription/SpeechChunker.swift   VAD по энергии, нарезка на фрагменты, детектор «потерянной речи»
  Transcription/Transcript.swift      модель данных, абзацы, TranscriptCleaner (чистка галлюцинаций)
  Transcription/TranscriptExporter.swift  TXT и DOCX
  Transcription/AudioPreparer.swift   декодирование любого файла → WAV 16 кГц моно 16 бит + энергии по 10 мс
  Support/                         WAV, ZIP-писатель (для DOCX), CRC32, поиск внешних утилит, форматирование времени
  Views/                           SwiftUI-экраны: RecordView, TranscribeView, SettingsView («Модели и настройки»), MenuBarView, ContentView

windows/
  installer.iss                    Inno Setup (ru), ставит в {autopf}\ListenAndRecord, ярлыки
  ListenAndRecord/ListenAndRecord.csproj  net8.0-windows, WPF, self-contained win-x64, NAudio 2.2.1, копирует папку whisper\
  App.xaml(.cs)                    стили, глобальный обработчик ошибок (→ %LOCALAPPDATA%\ListenAndRecord\error.log), режим --selftest
  MainWindow.xaml(.cs)             весь UI: 3 вкладки, горячие клавиши (RegisterHotKey), строки менеджера моделей строятся в коде
  Core/AppSettings.cs              настройки JSON в %LOCALAPPDATA%\ListenAndRecord\settings.json
  Core/Hardware.cs                 ОЗУ, AVX2, ядра, имя CPU → рекомендация модели/режима, число потоков
  Core/ModelManager.cs             каталог, скачивание (HttpClient, .part → rename), импорт (копирование в папку Models)
  Recording/*                      то же, что на Mac (RecordingClock, TrackWriter, CallRecorder, AudioExporter)
  Transcription/*                  порт Mac-логики 1:1 + WhisperRunner (запуск whisper-cli.exe)
```

**Важно: логика расшифровки продублирована в Swift и C#** (`SpeechChunker`, `TranscriptCleaner`, `Transcript.paragraphs`,
`TranscriptExporter`, конвейер). При изменении алгоритма — меняй **обе** реализации одинаково.

---

## 4. Как устроена расшифровка (главная ценность проекта)

Исходная жалоба владельца: обычный whisper после паузы в разговоре «теряет» дальнейшую речь. Решение — многоуровневое:

1. **Декодирование** в 16 кГц моно 16 бит + RMS-энергия каждых 10 мс (`AudioPreparer`).
2. **Консервативный VAD по энергии** (`SpeechChunker.detectSpeech`): шум = 10-й перцентиль dB, громко = 95-й; порог = шум + clamp(25% диапазона, 6..15 dB);
   кадры тише −90 dB (цифровая тишина) игнорируются; при узком диапазоне (<10 dB) речью считается всё. Отрезки расширяются (−250/+450 мс)
   и склеиваются при разрыве ≤300 мс. Задача — **никогда не выкидывать тихую речь**, только явную тишину.
3. **Нарезка** (`splitLongRuns` + `makeChunks`): непрерывные отрезки >30 с режутся в самом тихом месте; фрагменты ≤60 с,
   разрез на паузах ≥2 с (если фрагмент уже ≥15 с); паузы >1,2 с внутри фрагмента **вырезаются** (сохраняется соответствие времени через `AudioPiece`,
   `SpeechChunk.sourceTime(local:)` переводит время фрагмента в время исходника).
4. **Whisper без «памяти»**: `no_context = true` и `n_max_text_ctx = 0` (в CLI: `-mc 0`) — каждый фрагмент и каждое 30-секундное окно
   распознаются независимо. Плюс `suppress_nst`, beam search 5 (или greedy в быстром режиме), язык по умолчанию `ru`.
5. **Silero VAD внутри whisper.cpp** (если модель скачана и включена): порог 0.4, min silence 300 мс, pad 200 мс (мягче дефолта).
6. **Детектор пропусков** (`looksIncomplete`): фрагмент ≥8 с подозрителен, если слов < 0,5 на секунду или есть участок >8 с без текста.
   Такие фрагменты **перераспознаются** кусками ≤20 с без VAD; новый вариант берётся, только если слов больше в 1,15 раза + 3.
7. **Чистка** (`TranscriptCleaner.clean`): удаляются пустые/«[музыка]»-аннотации и типичные галлюцинации в тишине
   («субтитр», «продолжение следует», «спасибо за просмотр», «DimaTorzok», «amara.org»… — только в сегментах ≤14 слов).
   Зацикливание (одна фраза 3+ раза подряд) схлопывается **только внутри одного вызова whisper и только если повторы идут без паузы** (<1,5 с);
   на итоговом списке `collapseLoops: false`. (Раньше схлопывалось глобально — это удаляло настоящие повторы; баг пойман самотестом.)
8. **Абзацы**: новый абзац после паузы ≥2 с или при длине ≥700 символов на конце предложения.

---

## 5. Как устроена запись

- Обе дорожки пишутся отдельно; каждый буфер ставится на свою позицию по **общим часам** (`RecordingClock`): разрыв >100 мс (Mac) / >200 мс (Windows)
  заполняется тишиной, опережение — буфер отбрасывается. Это нужно, потому что Windows WASAPI loopback **не присылает данных, пока ничего не звучит**.
- Пауза: буферы, попавшие во время паузы, отбрасываются (часы исключают интервалы пауз).
- Временные файлы: Mac — `~/Library/Application Support/ListenAndRecord/Recordings/<дата>/{system,mic}.caf`;
  Windows — `%LOCALAPPDATA%\ListenAndRecord\Recordings\<дата>\{system,mic}.wav` (Flush каждые 5 с). Маркер `.saved` = уже сохранено;
  такие папки удаляются при следующей записи; несохранённая — предлагается при запуске.
- Mac: системный звук через ScreenCaptureKit требует разрешения «Запись экрана и системного звука» (видео 2×2 px, 1 fps, не используется);
  `excludesCurrentProcessAudio = true`. Микрофон — AVAudioEngine, перезапуск по `AVAudioEngineConfigurationChange`.
- Эхо: при разговоре через динамики голоса собеседников попадут и в микрофон. Рекомендуем наушники; шумо/эхоподавления нет.

---

## 6. Сборка и проверка

### macOS (у владельца — только Command Line Tools, без Xcode)
```bash
./scripts/build_app.sh                    # → build/ListenAndRecord.app
rm -rf /Applications/ListenAndRecord.app && cp -R build/ListenAndRecord.app /Applications/
build/ListenAndRecord.app/Contents/MacOS/ListenAndRecord --selftest <model.bin> <audio>   # консольный самотест
```

### Windows
```powershell
./scripts/build-whisper-windows.ps1       # нужен Visual Studio 2022 (C++), cmake, git
dotnet publish windows/ListenAndRecord/ListenAndRecord.csproj -c Release -r win-x64 --self-contained true -o build/windows-publish
build/windows-publish/ListenAndRecord.exe --selftest <model.bin> <audio> <out.txt>       # пишет результат в файл (у WinExe нет консоли)
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows/installer.iss                   # → build/ListenAndRecord-Setup.exe
```

### CI — основной способ проверки
Владелец не может сам отлаживать код, а у ассистента обычно нет macOS/Windows. Поэтому **после каждого изменения пушь в ветку и смотри CI**:
job `macos` (сборка + самотест на `ggml-base.bin`) и job `windows` (сборка whisper — кэшируется, publish, самотест, тест SSE4.2, установщик).
Не считай задачу выполненной, пока CI не зелёный. Если меняешь логику расшифровки — самотест с паузами обязан проходить на обеих платформах.

---

## 7. Подводные камни (уже наступали — не повторяй)

**macOS / Swift**
- В свежих SDK (macOS 27, Command Line Tools) `@State` — **макрос**, а плагин SwiftUI-макросов есть только в Xcode. **Не используй `@State`,
  `@Observable`, `#Preview`, `@Entry`** — для локального состояния View применяется маленький `ObservableObject` + `@StateObject`
  (`RecordFormState`, `DropState`, `EncoderState`). `@StateObject`, `@EnvironmentObject`, `@Published` работают.
- Пакет в режиме Swift 5 (`swift-tools-version:5.9`). Мутация захваченной `var` в `@Sendable`-замыкании — ошибка компиляции: используй класс-обёртку.
- Не используй key path к элементам кортежа (`\.code`) и `guard let (a, b) = …` — заменены структурами / явной распаковкой.
- Имя локальной переменной, совпадающее с вызываемой функцией (`let tracks = tracks(in:)`), даёт «circular reference».
- Длинные выражения с `??` и `<<` — «unable to type-check in reasonable time»: разбивай на переменные с явными типами.
- whisper.xcframework: смена версии = новый URL + checksum в `Package.swift` (`swift package compute-checksum` или sha256 zip).
  Релизы v1.9.3–v1.9.5 **не имеют** xcframework-ассета — последняя рабочая v1.9.2. Фреймворк копируется в `Contents/Frameworks`,
  rpath `@executable_path/../Frameworks` добавляет `build_app.sh`.
- Подпись ad-hoc: после каждой пересборки macOS может заново спросить разрешения. Это нормально.
- MP3 на Mac требует `brew install lame` (или ffmpeg); M4A/WAV — встроенные.

**Windows / C#**
- **Whisper.net сознательно не используется**: в его README заявлена только Windows 11 и требуется VC++ Redistributable; у владельца Windows 10.
  Вместо этого собственная сборка whisper.cpp: `GGML_BACKEND_DL=ON` + `GGML_CPU_ALL_VARIANTS=ON` (ggml-cpu-sse42.dll … haswell.dll,
  выбор под процессор во время работы), `GGML_OPENMP=OFF` и статический MSVC-рантайм (`MultiThreaded`) — никаких внешних зависимостей.
  GPU (Vulkan) не включён: GeForce 210 его не поддерживает; для Ryzen iGPU можно добавить позже (`GGML_VULKAN=ON` + Vulkan SDK в CI).
- `whisper-cli.exe` читает аргументы в ANSI-кодировке → **пути с кириллицей ломаются** (имя пользователя Windows может быть русским).
  Поэтому рабочая папка `%LOCALAPPDATA%\ListenAndRecord\work\<id>` лежит рядом с `Models`, и все пути передаются **относительными** (`WhisperRunner.Rel`).
  Импортированные модели **копируются** в папку Models. Не передавай whisper-cli абсолютные пути.
- Выход whisper-cli: для входа `chunk_0001.wav` создаётся `chunk_0001.wav.json` (`-oj`) и `.wav.txt`; прогресс — строки `processing '…'` в stderr.
- M4A/MP3 кодируются Media Foundation (в Windows N нужен Media Feature Pack). Вход для расшифровки читает `MediaFoundationReader`.
- Метод-группы с перегрузками (`Select(Path.GetFileName)`) неоднозначны — используй лямбды.
- В скриптах Python для Windows-CI вызывай `sys.stdout.reconfigure(encoding="utf-8")` (консоль cp1252).

---

## 8. Известные ограничения и идеи для развития

- Нет разделения по говорящим. Простой шаг: дорожки микрофона и системы уже раздельные → можно подписывать «Я» / «Собеседник»
  (расшифровывать дорожки отдельно и сливать по времени). Это нужно делать до сведения или хранить дорожки рядом с файлом.
- Нет эхоподавления (при работе без наушников).
- Windows: GPU не используется; нет иконки в трее; при закрытии окна во время записи запись останавливается.
- Mac: MP3 зависит от внешнего lame; нет автозапуска при старте звонка.
- Модели скачиваются без докачки после обрыва (Windows: файл `.part` удаляется при ошибке).
- whisper.cpp v1.9.2 содержит `parakeet` (NVIDIA Parakeet) — возможная альтернатива/ускорение, не исследовано.
- Версии: Mac `CFBundleShortVersionString` 2.0 (Resources/Info.plist), Windows `<Version>2.0.0` (csproj) и `AppVersion` в installer.iss — обновляй вместе.

## 9. Правила работы

- Отвечай владельцу по-русски, давай точные команды для Терминала / PowerShell, объясняй, где нажать.
- Не ломай существующие функции; делай небольшие проверяемые коммиты с понятным описанием.
- Меняя общую логику — меняй Swift и C# синхронно. Меняя версии whisper.cpp — обновляй обе платформы и CI.
- Пользовательские тексты в UI — на русском.
- После изменений: push → дождаться зелёного CI → дать владельцу ссылку на артефакты и инструкцию по установке.
