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
            RollingVoice(id: nil, isActive: false, targetAmplitude: 0, targetFilterAlpha: 0, currentAmplitude: 0, currentFilterAlpha: 0, lastSample: 0)
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
                
                // 1. Generate White Noise component for rolling friction
                let whiteNoise = Float.random(in: -1.0...1.0)
                
                // 2. Synthesize Rolling Rumble (Noise + dynamic Low Pass Filter)
                for index in 0..<self.maxRollingVoices {
                    var voice = self.rollingVoices[index]
                    guard voice.isActive else { continue }
                    
                    // Smoothly interpolate parameters to prevent clicks
                    voice.currentAmplitude += (voice.targetAmplitude - voice.currentAmplitude) * 0.004
                    voice.currentFilterAlpha += (voice.targetFilterAlpha - voice.currentFilterAlpha) * 0.004
                    
                    // RC Low Pass Filter: y[n] = alpha * x[n] + (1 - alpha) * y[n-1]
                    let filteredNoise = voice.currentFilterAlpha * whiteNoise + (1.0 - voice.currentFilterAlpha) * voice.lastSample
                    voice.lastSample = filteredNoise
                    
                    frameSample += filteredNoise * voice.currentAmplitude
                    
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
    /// - Parameter activeRolls: List of rolling balls with their IDs, mass, and current speed.
    func updateRollingVoices(activeRolls: [(id: UUID, mass: CGFloat, speed: CGFloat)]) {
        guard isSoundEnabled else { return }
        
        lock.lock()
        
        // Mark all current slots as "not updated" this frame so we can fade out missing ones
        var updatedIndices = Set<Int>()
        
        for roll in activeRolls {
            // Threshold speed for rolling sounds (below 35 px/s, it stays silent)
            let minSpeed: Double = 35.0
            let maxSpeed: Double = 900.0
            
            let targetAmp: Float
            let targetFilter: Float
            
            if Double(roll.speed) < minSpeed {
                targetAmp = 0.0
                targetFilter = 0.04
            } else {
                let speedDelta = Double(roll.speed) - minSpeed
                let speedRatio = min(speedDelta / (maxSpeed - minSpeed), 1.0)
                
                // Exponential volume mapping (quadratic) to match human hearing logarithmics
                let expSpeedRatio = speedRatio * speedRatio
                
                // Increased volume coefficient (up to 0.45) for richer rumbles
                let maxRollingVolume: Float = 0.45
                targetAmp = Float(expSpeedRatio) * maxRollingVolume * Float(0.3 + 0.7 * min(Double(roll.mass) / 10.0, 1.0))
                
                // Dynamic LPF cutoff mapping
                targetFilter = Float(0.04 + 0.22 * speedRatio)
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
                        break
                    }
                }
            }
            
            // Update assigned slot target values
            if let index = slotIndex {
                rollingVoices[index].targetAmplitude = targetAmp
                rollingVoices[index].targetFilterAlpha = targetFilter
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
