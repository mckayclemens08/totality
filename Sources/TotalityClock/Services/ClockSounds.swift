import AVFoundation
import Foundation

/// The files alarms ring with, in the app's Library/Sounds folder, where iOS looks for both AlarmKit's and
/// notifications' named sounds. They're plain audio there, unencrypted, because iOS has to play them with
/// the app closed; nothing in that folder is ever uploaded.
public struct ClockSounds: Sendable {
    /// iOS plays at most 30 seconds of a notification's sound.
    public static let longest: TimeInterval = 30
    static let rate = 22_050.0

    let folder: URL

    public init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The file to ring with, made first if it's one of Totality's tones. Nil means iOS's own sound.
    public func file(for sound: ClockSound, own: [OwnSound]) -> String? {
        switch sound {
        case .standard:
            return nil
        case .tone(let tone):
            let name = "totality-\(tone.rawValue).wav"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard (try? write(Self.wave(for: tone), to: url)) != nil else { return nil }
            }
            return name
        case .own(let id):
            guard let sound = own.first(where: { $0.id == id }),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(sound.fileName).path)
            else { return nil }
            return sound.fileName
        }
    }

    /// Copies a sound the person picked into the folder as a WAV of at most 30 seconds, which both
    /// AlarmKit and notifications can play.
    public func add(from source: URL, named name: String) throws -> OwnSound {
        let id = UUID()
        let fileName = "totality-own-\(id.uuidString.lowercased()).wav"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let frames = AVAudioFrameCount(min(Double(input.length), format.sampleRate * Self.longest))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileReadCorruptFile) }
        try input.read(into: buffer, frameCount: frames)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: folder.appendingPathComponent(fileName), settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return OwnSound(id: id, name: cleaned.isEmpty ? "My sound" : String(cleaned.prefix(40)), fileName: fileName)
    }

    public func remove(_ sound: OwnSound) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(sound.fileName))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Tones

    /// A tone as a 16-bit mono WAV, drawn from sine waves, 20 seconds long.
    static func wave(for tone: ClockTone) -> Data {
        let seconds = 20.0
        let count = Int(rate * seconds)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / rate
            samples[index] = Int16(max(-1, min(1, level(tone, at: t))) * 0.6 * Double(Int16.max))
        }
        return wav(samples)
    }

    /// The tone's sound at `t` seconds, between -1 and 1.
    static func level(_ tone: ClockTone, at t: Double) -> Double {
        func sine(_ hertz: Double) -> Double { sin(2 * .pi * hertz * t) }
        switch tone {
        case .chime:
            // Two bell notes a second, each fading.
            let beat = t.truncatingRemainder(dividingBy: 1)
            let note = beat < 0.5 ? 880.0 : 659.25
            let local = beat.truncatingRemainder(dividingBy: 0.5)
            return (sine(note) + 0.4 * sine(note * 2)) / 1.4 * exp(-local * 6)
        case .pulse:
            // Four short beeps, then a rest.
            let beat = t.truncatingRemainder(dividingBy: 1.2)
            let on = beat < 0.8 && beat.truncatingRemainder(dividingBy: 0.2) < 0.1
            return on ? sine(1000) : 0
        case .rise:
            // A soft tone that climbs and gets louder over the first 10 seconds.
            let swell = min(1, 0.15 + t / 10)
            let step = 523.25 * pow(2, Double(Int(t * 2) % 4) / 12 * 4)
            return sine(step) * swell * (0.6 + 0.4 * sine(2))
        }
    }

    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) { put(value) }
        }
        return data
    }
}
