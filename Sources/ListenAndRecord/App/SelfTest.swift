import Foundation
import whisper

/// Hidden command-line mode used by CI to check that the embedded whisper.cpp works:
///   ListenAndRecord --selftest [model.bin audio-file]
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        print("whisper.cpp \(String(cString: whisper_version()))")
        guard args.count >= i + 3 else { exit(0) }
        let model = args[i + 1], audio = URL(fileURLWithPath: args[i + 2])
        let done = DispatchSemaphore(value: 0)
        let result = ExitCode()
        Task.detached {
            do {
                let engine = try WhisperEngine(modelPath: model)
                let options = WhisperDecodeOptions(language: "en", threads: 4, beamSize: 5, vadModelPath: nil)
                let pipeline = TranscriptionPipeline(engine: engine, options: options, recoverGaps: true,
                                                     prepare: AudioPreparer.prepare)
                let transcript = try await pipeline.run(source: audio) { _ in }
                print(TranscriptExporter.plainText(transcript, timestamps: true))
                if transcript.segments.isEmpty { result.value = 2 }
            } catch {
                print("ERROR: \(error.localizedDescription)")
                result.value = 1
            }
            done.signal()
        }
        done.wait()
        exit(result.value)
    }
}

private final class ExitCode: @unchecked Sendable {
    var value: Int32 = 0
}
