//
//  HapticManager.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import CoreHaptics
import UIKit

class HapticManager {
    static let shared = HapticManager()
    
    private var engine: CHHapticEngine?
    private var isSupported: Bool = false
    
    private init() {
        let hapticCapabilities = CHHapticEngine.capabilitiesForHardware()
        isSupported = hapticCapabilities.supportsHaptics
        
        if isSupported {
            do {
                engine = try CHHapticEngine()
                engine?.playsHapticsOnly = true
                
                engine?.resetHandler = { [weak self] in
                    print("Haptic Engine Reset")
                    do {
                        try self?.engine?.start()
                    } catch {
                        print("Failed to restart Haptic Engine: \(error)")
                    }
                }
                
                engine?.stoppedHandler = { reason in
                    print("Haptic Engine Stopped: \(reason)")
                }
                
                try engine?.start()
            } catch {
                print("Failed to initialize Haptic Engine: \(error)")
            }
        }
    }
    
    /// Play a collision thud, modulating intensity and sharpness based on simulated forces.
    func playCollisionHaptic(intensity: Float, sharpness: Float) {
        guard isSupported, let engine = engine else {
            // Fallback to standard impact feedback if CoreHaptics is not available/failed
            let generator = UIImpactFeedbackGenerator(style: intensity > 0.6 ? .heavy : (intensity > 0.3 ? .medium : .light))
            generator.prepare()
            generator.impactOccurred()
            return
        }
        
        // Clamp parameters to [0, 1]
        let intensityVal = min(max(intensity, 0.05), 1.0)
        let sharpnessVal = min(max(sharpness, 0.05), 1.0)
        
        let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityVal)
        let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessVal)
        
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensityParam, sharpnessParam], relativeTime: 0)
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start() // Ensure engine is running
            try player.start(atTime: 0)
        } catch {
            print("Failed to play collision haptic: \(error)")
        }
    }
    
    // Continuous haptics for drag and motion
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isContinuousPlaying = false
    
    func startContinuousHaptic(intensity: Float, sharpness: Float) {
        guard isSupported, let engine = engine else { return }
        
        if isContinuousPlaying {
            updateContinuousHaptic(intensity: intensity, sharpness: sharpness)
            return
        }
        
        let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
        let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensityParam, sharpnessParam],
            relativeTime: 0,
            duration: 100.0 // Long-running haptic, we stop/modulate it manually
        )
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try engine.start()
            try continuousPlayer?.start(atTime: 0)
            isContinuousPlaying = true
        } catch {
            print("Failed to start continuous haptic: \(error)")
        }
    }
    
    func updateContinuousHaptic(intensity: Float, sharpness: Float) {
        guard isSupported, isContinuousPlaying, let player = continuousPlayer else { return }
        
        let intensityVal = min(max(intensity, 0.01), 1.0)
        let sharpnessVal = min(max(sharpness, 0.0), 1.0)
        
        let intensityControl = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensityVal, relativeTime: 0)
        let sharpnessControl = CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpnessVal, relativeTime: 0)
        
        do {
            try player.sendParameters([intensityControl, sharpnessControl], atTime: 0)
        } catch {
            // If the player stopped, restart it
            isContinuousPlaying = false
            startContinuousHaptic(intensity: intensityVal, sharpness: sharpnessVal)
        }
    }
    
    func stopContinuousHaptic() {
        guard isSupported, isContinuousPlaying, let player = continuousPlayer else { return }
        do {
            try player.stop(atTime: 0)
            isContinuousPlaying = false
        } catch {
            print("Failed to stop continuous haptic: \(error)")
        }
    }
}
