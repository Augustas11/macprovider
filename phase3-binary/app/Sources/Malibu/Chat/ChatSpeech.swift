@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum ChatDictationGate {
    static let onDevice = "Voice input needs on-device recognition on this Mac."
    static let permission = "Allow microphone and speech recognition to dictate a message."
    static let failed = "Voice input could not start."
    static let noSpeech = "Voice input did not hear any speech."

    static func refusal(recognizerOnDevice: Bool, speechAuthorized: Bool, microphoneAuthorized: Bool) -> String? {
        if !recognizerOnDevice { return onDevice }
        if !speechAuthorized || !microphoneAuthorized { return permission }
        return nil
    }
}

/// Dictation stays on this Mac: the request requires on-device recognition.
@MainActor
final class ChatDictation: ObservableObject {
    @Published private(set) var isListening = false
    private let engine = DictationEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var base = ""
    private var heard = false
    private var pending = false
    private var generation = 0
    private var onText: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?

    func toggle(base: String, onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        if isListening || pending { stop(); return }
        generation += 1
        let generation = generation
        self.base = base
        self.onText = onText
        self.onFailure = onFailure
        heard = false
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            onFailure(ChatDictationGate.onDevice)
            return
        }
        self.recognizer = recognizer
        pending = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            let authorized = status == .authorized
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.requestMicrophone(speechAuthorized: authorized, generation: generation)
            }
        }
    }

    func stop() {
        generation += 1
        pending = false
        task?.cancel()
        task = nil
        engine.stop()
        isListening = false
        onText = nil
        onFailure = nil
    }

    /// The original draft plus the latest transcript, cut to the composer's byte limit.
    static func cappedDraft(base: String, heard: String) -> String {
        let prefix = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? heard : prefix + " " + heard
        return utf8Prefix(combined, bytes: ChatStore.maxPromptBytes)
    }

    private static func utf8Prefix(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit, limit >= 0 else { return text }
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = character.utf8.count
            if used + size > limit { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    private func requestMicrophone(speechAuthorized: Bool, generation: Int) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.begin(speechAuthorized: speechAuthorized, microphone: granted, generation: generation)
            }
        }
    }

    private func begin(speechAuthorized: Bool, microphone: Bool, generation: Int) {
        guard self.generation == generation else { return }
        guard let recognizer else { pending = false; return }
        if let refusal = ChatDictationGate.refusal(recognizerOnDevice: recognizer.supportsOnDeviceRecognition,
                                                   speechAuthorized: speechAuthorized, microphoneAuthorized: microphone) {
            pending = false
            onFailure?(refusal)
            return
        }
        let request: SFSpeechAudioBufferRecognitionRequest
        do { request = try engine.start() }
        catch {
            engine.stop()
            pending = false
            onFailure?(ChatDictationGate.failed)
            return
        }
        guard self.generation == generation else {
            engine.stop()
            return
        }
        pending = false
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let text, !text.isEmpty {
                    self.heard = true
                    self.onText?(Self.cappedDraft(base: self.base, heard: text))
                }
                if finished {
                    let silent = !self.heard
                    let failure = self.onFailure
                    self.stop()
                    if silent { failure?(ChatDictationGate.noSpeech) }
                }
            }
        }
    }
}

/// Reads the latest answer with the system voice. No audio leaves this Mac.
@MainActor
final class ChatSpeaker: ObservableObject {
    @Published private(set) var speakingID: UUID?
    private let synthesizer = AVSpeechSynthesizer()
    private var sawSpeech = false

    func toggle(_ text: String, id: UUID) {
        if speakingID == id {
            stop()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let spoken = String(text.prefix(8_000))
        guard !spoken.isEmpty else { stop(); return }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        speakingID = id
        synthesizer.speak(utterance)
        sawSpeech = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
        sawSpeech = false
    }

    /// Clears the button once the utterance that was actually speaking has ended.
    func noteIfFinished() {
        guard speakingID != nil else { return }
        if synthesizer.isSpeaking {
            sawSpeech = true
            return
        }
        if sawSpeech {
            speakingID = nil
            sawSpeech = false
        }
    }
}

private enum DictationEngineFailure: Error {
    case invalid
}

/// Holds the recognition request so the audio tap can append without leaving this Mac.
private final class DictationEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let box = RecognitionBox()
    private var tapped = false

    deinit { stop() }

    func start() throws -> SFSpeechAudioBufferRecognitionRequest {
        stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw DictationEngineFailure.invalid }
        box.set(request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [box] buffer, _ in
            box.append(buffer)
        }
        tapped = true
        engine.prepare()
        do { try engine.start() }
        catch {
            stop()
            throw error
        }
        return request
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        box.endAudio()
    }
}

private final class RecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func endAudio() {
        lock.lock()
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}
