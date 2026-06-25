//
//  MotionManager.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import CoreMotion
import Combine

class MotionManager: ObservableObject {
    static let shared = MotionManager()
    
    private let motionManager = CMMotionManager()
    
    @Published var gravity: CGVector = .zero
    
    private init() {
        // Core Motion updates at 60Hz
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device Motion is not available on this device.")
            // Use dummy gravity (default down) if device motion is unavailable
            self.gravity = CGVector(dx: 0, dy: 0.8)
            return
        }
        
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion, error == nil else { return }
            
            // Extract the gravity vector
            // In iOS portrait orientation:
            // - motion.gravity.x represents side-to-side tilt (right is positive)
            // - motion.gravity.y represents forward-to-back tilt (up is positive)
            // SwiftUI coordinate system:
            // - x increases to the right (matches motion.gravity.x)
            // - y increases downwards (opposite of motion.gravity.y)
            
            let gx = motion.gravity.x
            let gy = -motion.gravity.y
            
            // Apply a noise filter threshold to prevent tiny oscillations when flat
            let threshold: Double = 0.02
            let dx = abs(gx) > threshold ? gx : 0.0
            let dy = abs(gy) > threshold ? gy : 0.0
            
            self.gravity = CGVector(dx: dx, dy: dy)
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
