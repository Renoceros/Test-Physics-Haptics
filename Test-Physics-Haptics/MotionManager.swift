//
//  MotionManager.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import CoreMotion
import CoreGraphics
import Combine

class MotionManager: ObservableObject {
    static let shared = MotionManager()
    
    private let motionManager = CMMotionManager()
    
    @Published var gravity: CGVector = .zero
    @Published var isAxisLocked: Bool = false {
        didSet {
            updateGravityVector()
        }
    }
    
    private var lastRawGravityX: Double = 0.0
    private var lastRawGravityY: Double = -0.8
    private var lastRawGravityZ: Double = 0.0
    
    private init() {
        // Core Motion updates at 60Hz
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    }
    
    private func updateGravityVector() {
        let mappedX: Double
        let mappedY: Double
        
        if isAxisLocked {
            let absX = abs(lastRawGravityX)
            let absY = abs(lastRawGravityY)
            let absZ = abs(lastRawGravityZ)
            
            if absZ >= absX && absZ >= absY {
                // Dominant axis is Z: lay flat -> zero gravity in-plane
                mappedX = 0.0
                mappedY = 0.0
            } else if absY >= absX && absY >= absZ {
                // Dominant axis is Y: portrait snap
                mappedX = 0.0
                // Raw CoreMotion gravity has -y pointing straight down (upright)
                mappedY = lastRawGravityY < 0.0 ? 1.0 : -1.0
            } else {
                // Dominant axis is X: landscape snap
                mappedX = lastRawGravityX > 0.0 ? 1.0 : -1.0
                mappedY = 0.0
            }
        } else {
            // Standard smooth analog tilt mapping
            let gx = lastRawGravityX
            let gy = -lastRawGravityY
            
            let threshold: Double = 0.02
            mappedX = abs(gx) > threshold ? gx : 0.0
            mappedY = abs(gy) > threshold ? gy : 0.0
        }
        
        self.gravity = CGVector(dx: mappedX, dy: mappedY)
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device Motion is not available on this device.")
            // Use dummy gravity (default down) if device motion is unavailable
            self.lastRawGravityX = 0.0
            self.lastRawGravityY = -0.8
            self.lastRawGravityZ = 0.0
            updateGravityVector()
            return
        }
        
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion, error == nil else { return }
            
            self.lastRawGravityX = motion.gravity.x
            self.lastRawGravityY = motion.gravity.y
            self.lastRawGravityZ = motion.gravity.z
            
            self.updateGravityVector()
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
