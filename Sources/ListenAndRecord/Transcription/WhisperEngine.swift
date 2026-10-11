import Foundation
import whisper

struct WhisperDecodeOptions {
    var language: String          // "auto", "ru", "en", ...
    var threads: Int
    var beamSize: Int             // 1 = greedy (fast), 5 = beam search (accurate)
    var vadModelPath: String?     // Silero VAD inside whisper.cpp; nil = off
}

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .modelLoadFailed(path):
            return "Не удалось загрузить модель Whisper: \(path). Файл повреждён или это не модель ggml — скачайте её заново на вкладке «Модели»."
        case let .transcriptionFailed(code):
            return "Ошибка распознавания (код \(code))."
        }
    }
}

/// Thin Swift wrapper over the embedded whisper.cpp library. One instance keeps the model
/// loaded; `transcribe` is blocking and must be called from a background thread.
final class WhisperEngine: @unchecked Sendable {
    let modelPath: String
    private let ctx: OpaquePointer
    private let lock = NSLock()

    private static let silenceLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    init(modelPath: String, useGPU: Bool = true) throws {
        _ = Self.silenceLogs
        self.modelPath = modelPath
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperEngineError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Transcribes 16 kHz mono samples. Returns segments in local (chunk) time.
    func transcribe(_ samples: [Float], options: WhisperDecodeOptions, cancel: CancelFlag) throws -> [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(options.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threads)
        // Never condition on previously decoded text — neither from earlier calls (no_context)
        // nor between 30 s windows of this call (n_max_text_ctx = 0, like `-mc 0`).
        // This is what makes Whisper get stuck or skip speech after pauses.
        params.no_context = true
        params.n_max_text_ctx = 0
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_nst = true
        params.beam_search.beam_size = Int32(max(options.beamSize, 1))
        params.greedy.best_of = 5

        let box = Unmanaged.passRetained(cancel)
        defer { box.release() }
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CancelFlag>.fromOpaque(userData).takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = box.toOpaque()

        let language = options.language
        let vadPath = options.vadModelPath ?? ""
        let status: Int32 = language.withCString { lang in
            vadPath.withCString { vad in
                params.language = lang
                params.detect_language = false
                if !vadPath.isEmpty {
                    params.vad = true
                    params.vad_model_path = vad
                    // Softer than the defaults so quiet speech is not discarded.
                    params.vad_params.threshold = 0.4
                    params.vad_params.min_silence_duration_ms = 300
                    params.vad_params.speech_pad_ms = 200
                }
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        if cancel.isCancelled { throw CancellationError() }
        guard status == 0 else { throw WhisperEngineError.transcriptionFailed(status) }

        var segments: [TranscriptSegment] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100   // centiseconds
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(TranscriptSegment(start: t0, end: max(t0, t1), text: text))
        }
        return segments
    }
}

/// Thread-safe cancellation flag readable from whisper.cpp's abort callback.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.locked { cancelled } }
    func cancel() { lock.locked { cancelled = true } }
}
