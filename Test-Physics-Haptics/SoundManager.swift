//
//  SoundManager.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import AVFoundation
import QuartzCore
import Combine

struct ImpactVoice {
    var frequency: Float
    var amplitude: Float
    var decayRate: Float
    var time: Float
    var isActive: Bool
}

struct RollingVoice {
    var id: UUID?
    var isActive: Bool
    var targetAmplitude: Float
    var targetFilterAlpha: Float
    var currentAmplitude: Float
    var currentFilterAlpha: Float
    var lastSample: Float
    var seed: UInt32
    var targetSpeed: Float
    var currentSpeed: Float
    var phase: Float
    var lastHPFIn: Float
    var lastHPFOut: Float
    
    // Resonator target coefficients
    var target_b1_0: Float; var target_b2_0: Float; var target_g0: Float
    var target_b1_1: Float; var target_b2_1: Float; var target_g1: Float
    var target_b1_2: Float; var target_b2_2: Float; var target_g2: Float
    
    // Resonator current coefficients (smoothly interpolated)
    var b1_0: Float; var b2_0: Float; var g0: Float
    var b1_1: Float; var b2_1: Float; var g1: Float
    var b1_2: Float; var b2_2: Float; var g2: Float
    
    // Resonator states
    var y1_0: Float; var y2_0: Float
    var y1_1: Float; var y2_1: Float
    var y1_2: Float; var y2_2: Float
}

class SoundManager: ObservableObject {
    static let shared = SoundManager()
    
    // Settings configuration
    @Published var isSoundEnabled: Bool = true {
        didSet {
            if !isSoundEnabled {
                silenceAllRolling()
            }
        }
    }
    @Published var isRollingSoundEnabled: Bool = true {
        didSet {
            if !isRollingSoundEnabled {
                silenceAllRolling()
            }
        }
    }
    @Published var masterVolume: Float = 0.6
    
    private var engine: AVAudioEngine
    private var sourceNode: AVAudioSourceNode?
    
    // Synchronization locks
    private let lock = NSLock()
    
    // Pre-allocated voice pools for the audio thread
    private let maxImpactVoices = 16
    private var impactVoices: [ImpactVoice]
    
    private let maxRollingVoices = 8
    private var rollingVoices: [RollingVoice]
    
    private var sampleRate: Double = 44100.0
    private var isEngineRunning = false
    
    private init() {
        // Initialize voice arrays
        self.impactVoices = Array(repeating: ImpactVoice(frequency: 0, amplitude: 0, decayRate: 0, time: 0, isActive: false), count: maxImpactVoices)
        
        self.rollingVoices = (0..<maxRollingVoices).map { _ in
            RollingVoice(
                id: nil, isActive: false, targetAmplitude: 0, targetFilterAlpha: 0, currentAmplitude: 0, currentFilterAlpha: 0, lastSample: 0, seed: UInt32.random(in: 1...UInt32.max), targetSpeed: 0, currentSpeed: 0, phase: 0, lastHPFIn: 0, lastHPFOut: 0,
                target_b1_0: 0, target_b2_0: 0, target_g0: 0,
                target_b1_1: 0, target_b2_1: 0, target_g1: 0,
                target_b1_2: 0, target_b2_2: 0, target_g2: 0,
                b1_0: 0, b2_0: 0, g0: 0,
                b1_1: 0, b2_1: 0, g1: 0,
                b1_2: 0, b2_2: 0, g2: 0,
                y1_0: 0, y2_0: 0,
                y1_1: 0, y2_1: 0,
                y1_2: 0, y2_2: 0
            )
        }
        
        self.engine = AVAudioEngine()
        setupAudioSession()
        setupAudioEngine()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Failed to set up AVAudioSession: \(error)")
        }
    }
    
    private func setupAudioEngine() {
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        self.sampleRate = outputFormat.sampleRate
        
        // Define the real-time DSP callback block
        sourceNode = AVAudioSourceNode { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            guard let self = self else { return noErr }
            
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let channelCount = Int(buffers.count)
            let frames = Int(frameCount)
            
            // Audio thread safety: quickly lock and fetch current voice states
            self.lock.lock()
            
            // Render sample by sample
            for frame in 0..<frames {
                var frameSample: Float = 0.0
                
                // 1. Synthesize Rolling Rumble (Noise + dynamic Low Pass Filter + Crackle + Pitch-modulated Hum)
                for index in 0..<self.maxRollingVoices {
                    var voice = self.rollingVoices[index]
                    guard voice.isActive else { continue }
                    
                    // Smoothly interpolate parameters to prevent clicks
                    voice.currentAmplitude += (voice.targetAmplitude - voice.currentAmplitude) * 0.004
                    voice.currentFilterAlpha += (voice.targetFilterAlpha - voice.currentFilterAlpha) * 0.004
                    voice.currentSpeed += (voice.targetSpeed - voice.currentSpeed) * 0.004
                    
                    // 1a. Generate voice-specific white noise using LCG
                    voice.seed = voice.seed &* 1664525 &+ 1013904223
                    let voiceNoise = Float(Int32(truncatingIfNeeded: voice.seed)) / 2147483647.0
                    
                    // 1b. Alpha Jitter to break monotone filtering
                    voice.seed = voice.seed &* 1664525 &+ 1013904223
                    let jitterRaw = Float(Int16(truncatingIfNeeded: voice.seed & 0xFFFF)) / 32768.0
                    let alphaJitter = jitterRaw * 0.008
                    let alpha = max(0.005, min(0.995, voice.currentFilterAlpha + alphaJitter))
                    
                    // 1c. Granular Dust Crackle (0.04% probability per sample)
                    voice.seed = voice.seed &* 1664525 &+ 1013904223
                    var crackleSample: Float = 0.0
                    if (voice.seed & 0xFFFF) < 26 {
                        let sign: Float = ((voice.seed >> 16) & 1) == 0 ? -1.0 : 1.0
                        crackleSample = sign * 0.35
                    }
                    
                    // 1d. Cyclic Rolling Hum (frequency proportional to speed)
                    let humFrequency = 25.0 + voice.currentSpeed * 0.35
                    voice.phase += (2.0 * Float.pi * humFrequency) / Float(self.sampleRate)
                    if voice.phase > 2.0 * Float.pi {
                        voice.phase -= 2.0 * Float.pi
                    }
                    let humSample = (sin(voice.phase) + 0.3 * sin(voice.phase * 2.0)) * 0.12
                    
                    // RC Low Pass Filter: y[n] = alpha * x[n] + (1 - alpha) * y[n-1]
                    let filteredNoise = alpha * voiceNoise + (1.0 - alpha) * voice.lastSample
                    voice.lastSample = filteredNoise
                    
                    // 1e. First-order High Pass Filter (HPF) at ~140Hz to remove sub-bass mud
                    let hpfBeta: Float = 0.98
                    let filteredHPF = hpfBeta * (voice.lastHPFOut + filteredNoise - voice.lastHPFIn)
                    voice.lastHPFIn = filteredNoise
                    voice.lastHPFOut = filteredHPF
                    
                    // Mix band-passed noise, crackle, and cyclic hum
                    let excitation = filteredHPF + crackleSample + humSample
                    
                    // Smoothly interpolate filter coefficients to prevent digital aliasing (zipper noise)
                    voice.b1_0 += (voice.target_b1_0 - voice.b1_0) * 0.002
                    voice.b2_0 += (voice.target_b2_0 - voice.b2_0) * 0.002
                    voice.g0 += (voice.target_g0 - voice.g0) * 0.002
                    
                    voice.b1_1 += (voice.target_b1_1 - voice.b1_1) * 0.002
                    voice.b2_1 += (voice.target_b2_1 - voice.b2_1) * 0.002
                    voice.g1 += (voice.target_g1 - voice.g1) * 0.002
                    
                    voice.b1_2 += (voice.target_b1_2 - voice.b1_2) * 0.002
                    voice.b2_2 += (voice.target_b2_2 - voice.b2_2) * 0.002
                    voice.g2 += (voice.target_g2 - voice.g2) * 0.002
                    
                    // 1f. Pass excitation through 3 physical modal resonators of the ball
                    let y0 = voice.g0 * excitation - voice.b1_0 * voice.y1_0 - voice.b2_0 * voice.y2_0
                    voice.y2_0 = voice.y1_0
                    voice.y1_0 = y0
                    
                    let y1 = voice.g1 * excitation - voice.b1_1 * voice.y1_1 - voice.b2_1 * voice.y2_1
                    voice.y2_1 = voice.y1_1
                    voice.y1_1 = y1
                    
                    let y2 = voice.g2 * excitation - voice.b1_2 * voice.y1_2 - voice.b2_2 * voice.y2_2
                    voice.y2_2 = voice.y1_2
                    voice.y1_2 = y2
                    
                    // Combine resonator outputs and scale by voice volume
                    let rollingAcoustics = y0 + y1 + y2
                    frameSample += rollingAcoustics * voice.currentAmplitude
                    
                    // Deactivate slot if it faded out completely
                    if voice.targetAmplitude == 0.0 && voice.currentAmplitude < 0.0005 {
                        voice.isActive = false
                        voice.id = nil
                    }
                    
                    self.rollingVoices[index] = voice
                }
                
                // 3. Synthesize Collision Resonators (Modal Additive Synthesis with Overtones)
                for index in 0..<self.maxImpactVoices {
                    var voice = self.impactVoices[index]
                    guard voice.isActive else { continue }
                    
                    let t = voice.time
                    let env = exp(-voice.decayRate * t)
                    
                    // Fundamental frequency (f0)
                    var wave = sin(2.0 * Float.pi * voice.frequency * t)
                    
                    // Overtone 1 (1.6 * f0, decays 1.5x faster)
                    wave += 0.5 * exp(-voice.decayRate * 1.5 * t) * sin(2.0 * Float.pi * voice.frequency * 1.6 * t)
                    
                    // Overtone 2 (2.3 * f0, decays 2.0x faster)
                    wave += 0.25 * exp(-voice.decayRate * 2.0 * t) * sin(2.0 * Float.pi * voice.frequency * 2.3 * t)
                    
                    let signal = voice.amplitude * env * wave
                    frameSample += signal
                    
                    voice.time += Float(1.0 / self.sampleRate)
                    
                    // Turn off voice when it decays below threshold
                    if env < 0.0005 {
                        voice.isActive = false
                    }
                    
                    self.impactVoices[index] = voice
                }
                
                // Apply master volume and safe soft-clipping limiter to avoid digital distortion
                var finalSample = frameSample * self.masterVolume
                if finalSample > 1.0 { finalSample = 1.0 }
                else if finalSample < -1.0 { finalSample = -1.0 }
                
                // Write mono sample to all output channels
                for channel in 0..<channelCount {
                    let ptr = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                    ptr?[frame] = finalSample
                }
            }
            
            self.lock.unlock()
            return noErr
        }
        
        guard let sourceNode = sourceNode else { return }
        engine.attach(sourceNode)
        
        // Connect nodes
        engine.connect(sourceNode, to: mainMixer, format: outputFormat)
        
        // Watch for audio route changes (plugs, bluetooth, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        startEngine()
    }
    
    func startEngine() {
        guard !isEngineRunning else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            print("Failed to start AVAudioEngine: \(error)")
        }
    }
    
    func stopEngine() {
        guard isEngineRunning else { return }
        engine.stop()
        isEngineRunning = false
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        // Restart engine if interrupted by routing change (e.g. plugging headphones)
        DispatchQueue.main.async { [weak self] in
            self?.startEngine()
        }
    }
    
    // MARK: - Voice Control APIs
    
    /// Trigger an impact thud.
    /// - Parameters:
    ///   - mass: Mass of the ball (modulates frequency/pitch).
    ///   - size: Size/diameter of the ball (modulates pitch).
    ///   - bounciness: Coef of restitution (modulates decay time).
    ///   - impulse: Relative physical force of impact (modulates volume).
    func playCollision(mass: CGFloat, size: CGFloat, bounciness: CGFloat, impulse: CGFloat) {
        guard isSoundEnabled else { return }
        
        // Mathematical pitch mapping: smaller, lighter balls click higher; large, heavy balls thud deep.
        let baseFreq = 75.0
        let massWeight = 750.0 / sqrt(Double(mass))
        let freq = Float(baseFreq + massWeight)
        
        // Scale amplitude by impact force impulse
        let volumeScaler = 0.5
        let amp = Float(min(Double(impulse) / 1000.0 * volumeScaler, 1.0))
        
        // Scale decay rate: high bounciness -> slow decay (ringing); low bounciness -> fast decay (dead thud)
        let decay = Float(65.0 - 48.0 * Double(bounciness))
        
        lock.lock()
        
        // Find an empty slot or overwrite the oldest active slot
        var targetIndex = 0
        var foundSlot = false
        var oldestTime: Float = -1.0
        var oldestIndex = 0
        
        for i in 0..<maxImpactVoices {
            if !impactVoices[i].isActive {
                targetIndex = i
                foundSlot = true
                break
            }
            if impactVoices[i].time > oldestTime {
                oldestTime = impactVoices[i].time
                oldestIndex = i
            }
        }
        
        if !foundSlot {
            targetIndex = oldestIndex
        }
        
        impactVoices[targetIndex] = ImpactVoice(
            frequency: freq,
            amplitude: amp,
            decayRate: decay,
            time: 0.0,
            isActive: true
        )
        
        lock.unlock()
    }
    
    /// Update the states of all active rolling balls.
    /// - Parameter activeRolls: List of rolling balls with their IDs, mass, speed, and bounciness.
    func updateRollingVoices(activeRolls: [(id: UUID, mass: CGFloat, speed: CGFloat, bounciness: CGFloat)]) {
        guard isSoundEnabled && isRollingSoundEnabled else { return }
        
        lock.lock()
        
        // Mark all current slots as "not updated" this frame so we can fade out missing ones
        var updatedIndices = Set<Int>()
        
        for roll in activeRolls {
            // Threshold speed for rolling sounds (below 35 px/s, it stays silent)
            let minSpeed: Double = 35.0
            let maxSpeed: Double = 900.0
            
            let targetAmp: Float
            let targetFilter: Float
            
            // Calculate coefficients based on ball's physical size, mass, and bounciness
            let baseFreq = 65.0
            let massWeight = 600.0 / sqrt(Double(roll.mass))
            let f0 = Float(baseFreq + massWeight)
            let f1 = f0 * 1.6
            let f2 = f0 * 2.3
            
            // Rolling contact damping: higher bounciness -> less damping (rings more); low bounciness -> high damping (dull wood/rubber hum)
            let decay = Float(130.0 - 90.0 * Double(roll.bounciness))
            let dt = 1.0 / Float(sampleRate)
            
            // Resonator 0
            let theta0 = 2.0 * Float.pi * f0 * dt
            let R0 = exp(-decay * dt)
            let b1_0 = -2.0 * R0 * cos(theta0)
            let b2_0 = R0 * R0
            let g0 = (1.0 - b2_0) * sin(theta0) * 0.40
            
            // Resonator 1
            let theta1 = 2.0 * Float.pi * f1 * dt
            let R1 = exp(-decay * 1.5 * dt)
            let b1_1 = -2.0 * R1 * cos(theta1)
            let b2_1 = R1 * R1
            let g1 = (1.0 - b2_1) * sin(theta1) * 0.18
            
            // Resonator 2
            let theta2 = 2.0 * Float.pi * f2 * dt
            let R2 = exp(-decay * 2.0 * dt)
            let b1_2 = -2.0 * R2 * cos(theta2)
            let b2_2 = R2 * R2
            let g2 = (1.0 - b2_2) * sin(theta2) * 0.08
            
            if Double(roll.speed) < minSpeed {
                targetAmp = 0.0
                targetFilter = 0.04
            } else {
                let speedDelta = Double(roll.speed) - minSpeed
                let speedRatio = min(speedDelta / (maxSpeed - minSpeed), 1.0)
                
                // Exponential volume mapping (quadratic) to match human hearing logarithmics
                let expSpeedRatio = speedRatio * speedRatio
                
                // Reduced max rolling volume coefficient to keep noise subtle
                let maxRollingVolume: Float = 0.18
                targetAmp = Float(expSpeedRatio) * maxRollingVolume * Float(0.3 + 0.7 * min(Double(roll.mass) / 10.0, 1.0))
                
                // Dynamic LPF cutoff mapping (lowered range to cut high-frequency hiss)
                targetFilter = Float(0.015 + 0.055 * speedRatio)
            }
            
            // Find existing slot matching this ball ID
            var slotIndex: Int?
            for i in 0..<maxRollingVoices {
                if rollingVoices[i].isActive && rollingVoices[i].id == roll.id {
                    slotIndex = i
                    break
                }
            }
            
            // Assign a new slot if not found
            if slotIndex == nil {
                for i in 0..<maxRollingVoices {
                    if !rollingVoices[i].isActive {
                        slotIndex = i
                        rollingVoices[i].id = roll.id
                        rollingVoices[i].isActive = true
                        rollingVoices[i].currentAmplitude = 0.0
                        rollingVoices[i].currentFilterAlpha = targetFilter
                        rollingVoices[i].lastSample = 0.0
                        rollingVoices[i].seed = UInt32.random(in: 1...UInt32.max)
                        rollingVoices[i].targetSpeed = Float(roll.speed)
                        rollingVoices[i].currentSpeed = 0.0
                        rollingVoices[i].phase = 0.0
                        rollingVoices[i].lastHPFIn = 0.0
                        rollingVoices[i].lastHPFOut = 0.0
                        rollingVoices[i].y1_0 = 0.0; rollingVoices[i].y2_0 = 0.0
                        rollingVoices[i].y1_1 = 0.0; rollingVoices[i].y2_1 = 0.0
                        rollingVoices[i].y1_2 = 0.0; rollingVoices[i].y2_2 = 0.0
                        
                        // Set initial targets and current values to match immediately
                        rollingVoices[i].target_b1_0 = b1_0; rollingVoices[i].target_b2_0 = b2_0; rollingVoices[i].target_g0 = g0
                        rollingVoices[i].target_b1_1 = b1_1; rollingVoices[i].target_b2_1 = b2_1; rollingVoices[i].target_g1 = g1
                        rollingVoices[i].target_b1_2 = b1_2; rollingVoices[i].target_b2_2 = b2_2; rollingVoices[i].target_g2 = g2
                        rollingVoices[i].b1_0 = b1_0; rollingVoices[i].b2_0 = b2_0; rollingVoices[i].g0 = g0
                        rollingVoices[i].b1_1 = b1_1; rollingVoices[i].b2_1 = b2_1; rollingVoices[i].g1 = g1
                        rollingVoices[i].b1_2 = b1_2; rollingVoices[i].b2_2 = b2_2; rollingVoices[i].g2 = g2
                        break
                    }
                }
            }
            
            // Update assigned slot target values and coefficients
            if let index = slotIndex {
                rollingVoices[index].targetAmplitude = targetAmp
                rollingVoices[index].targetFilterAlpha = targetFilter
                rollingVoices[index].targetSpeed = Float(roll.speed)
                rollingVoices[index].target_b1_0 = b1_0; rollingVoices[index].target_b2_0 = b2_0; rollingVoices[index].target_g0 = g0
                rollingVoices[index].target_b1_1 = b1_1; rollingVoices[index].target_b2_1 = b2_1; rollingVoices[index].target_g1 = g1
                rollingVoices[index].target_b1_2 = b1_2; rollingVoices[index].target_b2_2 = b2_2; rollingVoices[index].target_g2 = g2
                updatedIndices.insert(index)
            }
        }
        
        // Fade out slots that are no longer active/updated (balls stopped or deleted)
        for i in 0..<maxRollingVoices {
            if rollingVoices[i].isActive && !updatedIndices.contains(i) {
                rollingVoices[i].targetAmplitude = 0.0
            }
        }
        
        lock.unlock()
    }
    
    private func silenceAllRolling() {
        lock.lock()
        for i in 0..<maxRollingVoices {
            rollingVoices[i].targetAmplitude = 0.0
            rollingVoices[i].currentAmplitude = 0.0
            rollingVoices[i].isActive = false
            rollingVoices[i].id = nil
        }
        lock.unlock()
    }
}
