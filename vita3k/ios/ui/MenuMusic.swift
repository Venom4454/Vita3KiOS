// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Home-menu music: an endless supply of original songs composed on the device.
//
// Every song comes from a random seed that picks a style, key, scale, chord progressions, motifs,
// rhythms and arrangement, so no two songs are the same. Inside a song the motifs repeat and follow
// the chords (that's what makes a tune stick). A small synthesizer plays it live: oscillators with
// envelopes and filters, synthesized drums and a ping-pong delay. Nothing is recorded or licensed.

import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - Random numbers

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(max(upperBound, 1))) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

// MARK: - Styles

struct MusicStyle {
    let name: String
    let bpm: ClosedRange<Int>
    let swing: Double // 0...0.33, delays every second 16th
    let leadWave: Int // 0 sine, 1 triangle, 2 square, 3 saw
    let padWave: Int
    let bassWave: Int
    let arpWave: Int
    let leadCutoff: Double // Hz
    let drums: Int // 0 none, 1 soft, 2 backbeat, 3 chip, 4 four-on-the-floor
    let arpRate: Int // 0 none, 1 eighths, 2 sixteenths
    let pad: Bool
    let sevenths: Bool
    let delayMix: Double
    let minorChance: Double
}

let musicStyles: [MusicStyle] = [
    MusicStyle(name: "Lo-fi", bpm: 72...86, swing: 0.2, leadWave: 1, padWave: 1, bassWave: 0, arpWave: 0,
               leadCutoff: 2400, drums: 1, arpRate: 0, pad: true, sevenths: true, delayMix: 0.22, minorChance: 0.4),
    MusicStyle(name: "Chiptune", bpm: 126...148, swing: 0, leadWave: 2, padWave: 2, bassWave: 1, arpWave: 2,
               leadCutoff: 5200, drums: 3, arpRate: 2, pad: false, sevenths: false, delayMix: 0.12, minorChance: 0.35),
    MusicStyle(name: "Dreamy", bpm: 64...76, swing: 0, leadWave: 0, padWave: 0, bassWave: 0, arpWave: 1,
               leadCutoff: 3000, drums: 0, arpRate: 1, pad: true, sevenths: true, delayMix: 0.35, minorChance: 0.3),
    MusicStyle(name: "City Pop", bpm: 100...116, swing: 0.08, leadWave: 1, padWave: 3, bassWave: 3, arpWave: 1,
               leadCutoff: 3600, drums: 2, arpRate: 1, pad: true, sevenths: true, delayMix: 0.18, minorChance: 0.25),
    MusicStyle(name: "Synthwave", bpm: 88...104, swing: 0, leadWave: 3, padWave: 3, bassWave: 3, arpWave: 2,
               leadCutoff: 2800, drums: 2, arpRate: 2, pad: true, sevenths: false, delayMix: 0.28, minorChance: 0.7),
    MusicStyle(name: "Bossa", bpm: 116...132, swing: 0.1, leadWave: 0, padWave: 1, bassWave: 0, arpWave: 1,
               leadCutoff: 2600, drums: 1, arpRate: 0, pad: true, sevenths: true, delayMix: 0.15, minorChance: 0.4),
]

private let majorScale = [0, 2, 4, 5, 7, 9, 11]
private let minorScale = [0, 2, 3, 5, 7, 8, 10]
private let dorianScale = [0, 2, 3, 5, 7, 9, 10]

// Chord progressions as scale degrees (0 = tonic). Classic pop, anime "royal road", jazz and modal ones.
private let progressions: [[Int]] = [
    [0, 4, 5, 3], [0, 5, 3, 4], [5, 3, 0, 4], [3, 4, 2, 5], [0, 3, 4, 3],
    [1, 4, 0, 5], [0, 2, 3, 4], [5, 4, 3, 4], [3, 0, 4, 5], [0, 3, 1, 4],
    [5, 1, 4, 0], [0, 6, 5, 4], [3, 4, 5, 5], [0, 4, 3, 3],
]

// 16-step rhythms (bit 15 = first step) for melodies: syncopated pop rhythms
private let leadRhythms: [UInt16] = [
    0b1010_0010_1000_1000, 0b1001_0010_0100_1000, 0b1000_1010_0010_1010, 0b1010_1000_1010_0000,
    0b1001_0000_1001_0100, 0b1000_0010_1000_0010, 0b1011_0000_1010_0000, 0b0010_1010_0010_1000,
    0b1000_1000_1001_0010, 0b1100_1000_1000_1000,
]

private let songAdjectives = ["Neon", "Velvet", "Paper", "Midnight", "Sunlit", "Electric", "Quiet", "Lucky", "Crystal",
                              "Silver", "Golden", "Hidden", "Faded", "Little", "Endless", "Pastel", "Cosmic", "Rainy",
                              "Sugar", "Lonely", "Bright", "Secret", "Wandering", "Floating", "Warm", "Starlit"]
private let songNouns = ["Harbor", "Arcade", "Garden", "Skyline", "Rooftop", "Lanterns", "Station", "Comet", "Summer",
                         "Tides", "Postcards", "Daydream", "Avenue", "Satellites", "Bloom", "Horizon", "Carousel",
                         "Lagoon", "Express", "Memories", "Fireflies", "Café", "Orbit", "Streetlights", "Waves", "Echoes"]

/// Title of the song a seed produces (same seed, same title)
func songTitle(seed: UInt64) -> String {
    var rng = SplitMix64(state: seed ^ 0xA5A5_5A5A_DEAD_BEEF)
    return "\(songAdjectives[rng.int(songAdjectives.count)]) \(songNouns[rng.int(songNouns.count)])"
}

// MARK: - Synthesizer

private struct Voice {
    var active = false
    var phase = 0.0
    var increment = 0.0
    var wave = 0
    var amplitude = 0.0
    var envelope = 0.0
    var attackStep = 0.0
    var attacking = false
    var decay = 0.9999 // per-sample multiplier while held
    var release = 0.999 // per-sample multiplier after the gate closes
    var gateSamples = 0
    var lowpass = 0.0
    var lowpassCoefficient = 0.2
    var pan = 0.5
}

/// Renders the music. Runs on the audio thread: no allocations or locks after init.
final class MusicSynth {
    private let sampleRate: Double
    private let voiceCount = 20
    private let voices: UnsafeMutablePointer<Voice>
    private let delayLength: Int
    private let delayLeft: UnsafeMutablePointer<Float>
    private let delayRight: UnsafeMutablePointer<Float>
    private var delayIndex = 0
    private var delaySamples = 1
    private var delayMix = 0.2

    // Song state
    private var rng = SplitMix64(state: 1)
    private(set) var seed: UInt64 = 0
    private(set) var styleIndex = 0
    private var style: MusicStyle = musicStyles[0]
    private var root = 57
    private var scale = majorScale
    private var progressionA = progressions[0]
    private var progressionB = progressions[1]
    private var motifA = [Int](repeating: -99, count: 16)
    private var motifB = [Int](repeating: -99, count: 16)
    private var sequenceMotif = true
    private var bassPattern = 0
    private var samplesPerStep = 5000.0
    private var sampleInStep = 0.0
    private var step = 0 // 16th notes since the song started
    private var songSteps = 44 * 16

    // Drums
    private var kickEnvelope = 0.0, kickPhase = 0.0, kickFrequency = 0.0
    private var snareEnvelope = 0.0, hatEnvelope = 0.0, hatPrevious = 0.0
    private var noiseState: UInt32 = 0x1234_5678

    // Control (written by the main thread)
    var volume = 0.6
    var preferredStyle = -1 // -1: any style
    private var gain = 0.0
    private var targetGain = 0.0
    private var skipRequested = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        voices = .allocate(capacity: voiceCount)
        voices.initialize(repeating: Voice(), count: voiceCount)
        delayLength = Int(sampleRate * 1.2)
        delayLeft = .allocate(capacity: delayLength)
        delayLeft.initialize(repeating: 0, count: delayLength)
        delayRight = .allocate(capacity: delayLength)
        delayRight.initialize(repeating: 0, count: delayLength)
        newSong(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        step = -1 // the first step plays once the first 16th has elapsed
    }

    deinit {
        voices.deallocate()
        delayLeft.deallocate()
        delayRight.deallocate()
    }

    func fadeIn() { targetGain = 1 }
    func fadeOut() { targetGain = 0 }
    func skip() { skipRequested = true }

    // MARK: Composition

    private func newSong(seed newSeed: UInt64) {
        seed = newSeed
        rng = SplitMix64(state: newSeed)
        styleIndex = preferredStyle >= 0 && preferredStyle < musicStyles.count ? preferredStyle : rng.int(musicStyles.count)
        style = musicStyles[styleIndex]
        let bpm = Double(style.bpm.lowerBound + rng.int(style.bpm.count))
        samplesPerStep = sampleRate * 60 / bpm / 4
        root = 52 + rng.int(12) // E3...D#4
        let minor = rng.chance(style.minorChance)
        scale = minor ? (rng.chance(0.4) ? dorianScale : minorScale) : majorScale
        progressionA = progressions[rng.int(progressions.count)]
        progressionB = progressions[rng.int(progressions.count)]
        makeMotif(into: &motifA)
        makeMotif(into: &motifB)
        sequenceMotif = rng.chance(0.6)
        bassPattern = rng.int(4)
        delayMix = style.delayMix
        delaySamples = min(Int(samplesPerStep * 3), delayLength - 1) // dotted eighth
        songSteps = (40 + 4 * rng.int(3)) * 16
        step = 0
        sampleInStep = 0
    }

    /// One bar of melody: scale degrees relative to the chord root, -99 = rest
    private func makeMotif(into motif: inout [Int]) {
        let rhythm = leadRhythms[rng.int(leadRhythms.count)]
        var degree = [0, 2, 4][rng.int(3)]
        for i in 0..<16 {
            if rhythm & (UInt16(1) << UInt16(15 - i)) != 0 {
                motif[i] = degree
                // Mostly stepwise, sometimes a leap; strong beats pull back to chord tones
                let move = [-2, -1, -1, 1, 1, 2, 3, -3][rng.int(8)]
                degree = max(-3, min(9, degree + move))
                if i % 4 == 2, ![0, 2, 4, 7].contains(degree) { degree = [0, 2, 4][rng.int(3)] }
            } else {
                motif[i] = -99
            }
        }
    }

    private func midiNote(degree: Int, octave: Int) -> Int {
        let octaveShift = Int((Double(degree) / 7).rounded(.down))
        let index = degree - octaveShift * 7
        return root + scale[index] + 12 * (octave + octaveShift)
    }

    private func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    private func play(midi: Int, wave: Int, amplitude: Double, attack: Double, gateSteps: Double,
                      decay: Double, release: Double, cutoff: Double, pan: Double) {
        var slot = -1
        var quietest = Double.greatestFiniteMagnitude
        for i in 0..<voiceCount {
            if !voices[i].active { slot = i; break }
            if voices[i].envelope < quietest { quietest = voices[i].envelope; slot = i }
        }
        var v = Voice()
        v.active = true
        v.increment = frequency(midi) / sampleRate
        v.wave = wave
        v.amplitude = amplitude
        v.attacking = true
        v.attackStep = 1 / max(attack * sampleRate, 1)
        v.decay = pow(0.001, 1 / max(decay * sampleRate, 1))
        v.release = pow(0.001, 1 / max(release * sampleRate, 1))
        v.gateSamples = Int(gateSteps * samplesPerStep)
        v.lowpassCoefficient = min(1, 2 * Double.pi * cutoff / sampleRate)
        v.pan = pan
        voices[slot] = v
    }

    private func onStep() {
        let bar = step / 16
        let position = step % 16
        let section: Int // 0 intro, 1 A, 2 B, 3 breakdown, 4 outro
        let totalBars = songSteps / 16
        switch bar {
        case 0..<4: section = 0
        case totalBars - 4..<totalBars: section = 4
        case 12..<20: section = 2
        case 28..<32: section = 3
        default: section = 1
        }
        let progression = section == 2 ? progressionB : progressionA
        let chord = progression[bar % 4]
        let lift = bar >= 20 && bar < 28 ? 1 : 0 // last chorus an octave up for the lead

        // Pad: the chord, held for the bar
        if position == 0 && style.pad {
            let tones = style.sevenths ? [0, 2, 4, 6] : [0, 2, 4]
            for (n, tone) in tones.enumerated() {
                play(midi: midiNote(degree: chord + tone, octave: 0), wave: style.padWave, amplitude: section == 3 ? 0.06 : 0.045,
                     attack: 0.25, gateSteps: 15, decay: 6, release: 0.8, cutoff: 1400, pan: 0.3 + 0.13 * Double(n))
            }
        }

        // Bass
        if section != 0 && section != 3 {
            let pattern: [Int] // steps where the bass plays
            switch bassPattern {
            case 0: pattern = [0, 8]
            case 1: pattern = [0, 6, 8, 14]
            case 2: pattern = [0, 3, 8, 11]
            default: pattern = [0, 4, 8, 12]
            }
            if pattern.contains(position) {
                let fifth = position == 8 && bassPattern == 2
                play(midi: midiNote(degree: chord + (fifth ? 4 : 0), octave: -2), wave: style.bassWave, amplitude: 0.22,
                     attack: 0.005, gateSteps: 3, decay: 0.9, release: 0.08, cutoff: 700, pan: 0.5)
            }
        }

        // Arpeggio
        if style.arpRate > 0 && section != 4 {
            let every = style.arpRate == 2 ? 1 : 2
            if position % every == 0 {
                let tones = [0, 2, 4, 7, 4, 2]
                let tone = tones[(position / every) % tones.count]
                play(midi: midiNote(degree: chord + tone, octave: 1), wave: style.arpWave, amplitude: section == 0 ? 0.05 : 0.07,
                     attack: 0.003, gateSteps: Double(every) * 0.8, decay: 0.35, release: 0.1, cutoff: 3200,
                     pan: position % (2 * every) == 0 ? 0.35 : 0.65)
            }
        }

        // Lead melody: motif A in A sections, motif B in B sections; follows the chords when sequenced
        if section == 1 || section == 2 {
            let motif = section == 2 ? motifB : motifA
            var degree = motif[position]
            if degree != -99 {
                if sequenceMotif { degree += chord }
                // Answer phrase: the 4th bar of each phrase lands on a chord tone
                if bar % 4 == 3 && position >= 8 { degree = chord + [0, 2, 4][position % 3] }
                var gate = 1.0
                var next = position + 1
                while next < 16 && motif[next] == -99 && gate < 4 { gate += 1; next += 1 }
                play(midi: midiNote(degree: degree, octave: 1 + lift), wave: style.leadWave, amplitude: 0.13,
                     attack: 0.01, gateSteps: gate * 0.9, decay: 1.2, release: 0.18, cutoff: style.leadCutoff, pan: 0.5)
            }
        }

        // Drums
        if style.drums != 0 && (section == 1 || section == 2) {
            switch style.drums {
            case 1: // soft
                if position == 0 || position == 10 { kick() }
                if position == 4 || position == 12 { snare(0.12) }
                if position % 2 == 0 { hat(0.04) }
            case 3: // chip
                if position % 8 == 0 { kick() }
                if position == 4 || position == 12 { snare(0.16) }
                if position % 2 == 0 { hat(0.05) }
            case 4: // four on the floor
                if position % 4 == 0 { kick() }
                if position == 4 || position == 12 { snare(0.14) }
                if position % 4 == 2 { hat(0.07) }
            default: // backbeat
                if position == 0 || position == 7 || position == 10 { kick() }
                if position == 4 || position == 12 { snare(0.18) }
                if position % 2 == 0 { hat(0.05) }
            }
            // Fill into each new phrase
            if bar % 4 == 3 && position >= 12 && position % 2 == 1 { snare(0.1) }
        }
    }

    private func kick() { kickEnvelope = 1; kickPhase = 0; kickFrequency = 125 }
    private func snare(_ level: Double) { snareEnvelope = level }
    private func hat(_ level: Double) { hatEnvelope = level }

    private func noise() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(noiseState) / Double(UInt32.max) * 2 - 1
    }

    // MARK: Rendering

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let fadeStep = 1 / (sampleRate * 0.9)
        for frame in 0..<frames {
            // Sequencer
            sampleInStep += 1
            let swingOffset = step % 2 == 1 ? style.swing * samplesPerStep : 0
            if sampleInStep >= samplesPerStep + swingOffset {
                sampleInStep = 0
                step += 1
                if step >= songSteps || skipRequested {
                    // Next song: a fresh seed, so the pool never runs out
                    if skipRequested { gain = 0 }
                    skipRequested = false
                    newSong(seed: rng.next() ^ UInt64(step)) // starts again at step 0
                }
                onStep()
            }

            var l = 0.0
            var r = 0.0
            for i in 0..<voiceCount where voices[i].active {
                var v = voices[i]
                v.phase += v.increment
                if v.phase >= 1 { v.phase -= 1 }
                let raw: Double
                switch v.wave {
                case 1: raw = 4 * abs(v.phase - 0.5) - 1
                case 2: raw = v.phase < 0.5 ? 0.6 : -0.6
                case 3: raw = (2 * v.phase - 1) * 0.7
                default: raw = sin(2 * Double.pi * v.phase)
                }
                v.lowpass += v.lowpassCoefficient * (raw - v.lowpass)
                if v.attacking {
                    v.envelope += v.attackStep
                    if v.envelope >= 1 { v.envelope = 1; v.attacking = false }
                } else if v.gateSamples > 0 {
                    v.envelope *= v.decay
                } else {
                    v.envelope *= v.release
                    if v.envelope < 0.0005 { v.active = false }
                }
                v.gateSamples -= 1
                let out = v.lowpass * v.envelope * v.amplitude
                l += out * (1 - v.pan) * 1.4
                r += out * v.pan * 1.4
                voices[i] = v
            }

            // Drums
            if kickEnvelope > 0.0005 {
                kickPhase += kickFrequency / sampleRate
                kickFrequency = 45 + (kickFrequency - 45) * 0.9993
                let k = sin(2 * Double.pi * kickPhase) * kickEnvelope * 0.45
                kickEnvelope *= 0.99975
                l += k
                r += k
            }
            if snareEnvelope > 0.0005 {
                let s = noise() * snareEnvelope
                snareEnvelope *= 0.9993
                l += s * 0.9
                r += s
            }
            if hatEnvelope > 0.0005 {
                let n = noise()
                let h = (n - hatPrevious) * hatEnvelope
                hatPrevious = n
                hatEnvelope *= 0.9965
                l += h * 0.8
                r += h * 1.1
            }

            // Ping-pong delay
            let readIndex = (delayIndex - delaySamples + delayLength) % delayLength
            let dl = Double(delayLeft[readIndex])
            let dr = Double(delayRight[readIndex])
            delayLeft[delayIndex] = Float(r * 0.5 + dr * 0.38)
            delayRight[delayIndex] = Float(l * 0.5 + dl * 0.38)
            delayIndex = (delayIndex + 1) % delayLength
            l += dl * delayMix
            r += dr * delayMix

            // Fade and soft clip
            if gain < targetGain { gain = min(targetGain, gain + fadeStep) } else if gain > targetGain { gain = max(targetGain, gain - fadeStep) }
            let master = gain * volume * 0.8
            l *= master
            r *= master
            left[frame] = Float(l / (1 + abs(l)))
            right[frame] = Float(r / (1 + abs(r)))
        }
    }
}

// MARK: - Player

/// Plays the home-menu music. Settings > Music turns it on/off and picks the volume and style.
@MainActor
final class MenuMusic: ObservableObject {
    static let shared = MenuMusic()

    @Published private(set) var nowPlaying = ""
    @Published private(set) var styleName = ""

    private let engine = AVAudioEngine()
    private var synth: MusicSynth?
    private var source: AVAudioSourceNode?
    private var wanted = false // the library is on screen
    private var titleTimer: Timer?
    private var stopWork: DispatchWorkItem?
    private var waitingForJIT = false

    var enabled: Bool { UserDefaults.standard.object(forKey: "v3k.musicEnabled") as? Bool ?? true }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuMusic.shared.pauseForBackground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if MenuMusic.shared.wanted { MenuMusic.shared.resume() } }
        }
        // The engine stops by itself whenever the audio session is reconfigured (SDL opening or closing
        // a game's audio, a route change, a call): start it again if the music should be playing
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                v3k_log_ui("Menu music: audio configuration changed, restarting")
                if MenuMusic.shared.wanted { MenuMusic.shared.resume() }
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated { if ended && MenuMusic.shared.wanted { MenuMusic.shared.resume() } }
        }
    }

    private func setUp() {
        guard synth == nil else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48000
        let newSynth = MusicSynth(sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned newSynth] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            newSynth.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        synth = newSynth
        source = node
        applySettings()
    }

    func applySettings() {
        synth?.volume = UserDefaults.standard.object(forKey: "v3k.musicVolume") as? Double ?? 0.6
        synth?.preferredStyle = UserDefaults.standard.object(forKey: "v3k.musicStyle") as? Int ?? -1
    }

    /// The library is showing
    func libraryShown() {
        wanted = true
        resume()
    }

    /// A game is starting: fade out and stop
    func libraryHidden() {
        wanted = false
        fadeOutAndStop()
    }

    func settingsChanged() {
        applySettings()
        if !enabled {
            fadeOutAndStop()
        } else if wanted {
            // Switching the source: the other one stops before the new one starts
            resume()
        }
    }

    func skip() {
        synth?.skip()
    }

    private func resume() {
        // Only on screen. The configuration-change and interruption-ended notifications also arrive in
        // the background (handing the audio session back to iOS is itself a configuration change), and
        // restarting from them took the session back and kept the music engine running off screen,
        // inside hosts that keep apps alive (LiveContainer, debugger-attached JIT). Other apps' videos
        // then would not play until the phone was restarted.
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        // Not while JIT is being prepared: the debugger freezes the app for a moment, which made the
        // music start, stutter and cut. Starts as soon as JIT is ready (also after Control Center)
        if v3k_jit_preparing() {
            guard !waitingForJIT else { return }
            waitingForJIT = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.waitingForJIT = false
                if self.wanted { self.resume() }
            }
            return
        }
        let session = AVAudioSession.sharedInstance()
        // No "other audio is playing" check: tools such as StikDebug keep a silent audio session alive in
        // the background, which made iOS report other audio all the time and the music never played.
        // The music mixes with other apps, and it can be turned off in Settings.
        // A game's audio may have deactivated the session when it closed
        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            v3k_log_ui("Menu music: audio session error: \(error.localizedDescription)")
        }
        setUp()
        stopWork?.cancel()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
                v3k_log_ui("Menu music: playing at \(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz")
            } catch {
                v3k_log_ui("Menu music: could not start audio: \(error.localizedDescription)")
            }
        }
        if VitaBGM.shared.isActive {
            // The Vita's own home music replaces the generated songs while it can be played
            synth?.fadeOut()
            VitaBGM.shared.play(volume: UserDefaults.standard.object(forKey: "v3k.musicVolume") as? Double ?? 0.6)
        } else {
            VitaBGM.shared.pause()
            synth?.fadeIn()
        }
        startTitleUpdates()
    }

    private func pauseForBackground() {
        stopWork?.cancel()
        synth?.fadeOut()
        VitaBGM.shared.pause()
        // stop, not pause: stop releases the audio hardware, so the session can be handed back
        engine.stop()
    }

    private func fadeOutAndStop() {
        synth?.fadeOut()
        VitaBGM.shared.pause()
        titleTimer?.invalidate()
        let work = DispatchWorkItem { [weak self] in self?.engine.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func startTitleUpdates() {
        titleTimer?.invalidate()
        updateTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MenuMusic.shared.updateTitle() }
        }
    }

    private func updateTitle() {
        guard let synth else { return }
        if VitaBGM.shared.isActive {
            if nowPlaying != "PS Vita home music" { nowPlaying = "PS Vita home music" }
            if styleName != "PS Vita" { styleName = "PS Vita" }
            return
        }
        let title = songTitle(seed: synth.seed)
        if title != nowPlaying { nowPlaying = title }
        let style = musicStyles[min(synth.styleIndex, musicStyles.count - 1)].name
        if style != styleName { styleName = style }
    }
}
