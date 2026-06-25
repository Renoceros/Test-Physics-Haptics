//
//  PhysicsEngine.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import SwiftUI
import CoreGraphics
import QuartzCore
import Combine

struct Ball: Identifiable, Equatable {
    let id: UUID
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var mass: CGFloat
    var rollingFriction: CGFloat // Ball-specific friction coefficient
    
    // Normalized density = mass / radius
    var density: CGFloat {
        return mass / radius
    }
}

class PhysicsEngine: NSObject, ObservableObject {
    @Published var balls: [Ball] = []

    // Simulation parameters
    @Published var planeFriction: CGFloat = 0.15 // Plane rolling friction coef
    @Published var edgeBounciness: CGFloat = 0.75 // Border bounciness (restitution)
    
    // Bounds of the simulation view, updated via GeometryReader
    var bounds: CGSize = .zero {
        didSet {
            // Keep existing balls inside bounds if bounds change
            adjustBallsToBounds()
        }
    }
    
    // Tracking active drag gesture
    @Published var draggedBallId: UUID?
    @Published var dragTouchPos: CGPoint = .zero
    
    // Display link for steady physics steps
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    
    // Physical Constants
    private let gravityMultiplier: CGFloat = 1100.0 // Pixels/s^2 multiplier for tilt gravity
    private let springStiffness: CGFloat = 20.0     // Spring constant (K) for rubberband drag
    private let springDamping: CGFloat = 4.0       // Damping constant (C) for rubberband drag
    private let baseFrictionDecel: CGFloat = 160.0 // Base deceleration for rolling friction
    
    override init() {
        super.init()
        setupInitialBalls()
    }
    
    func setupInitialBalls() {
        // Clear old ones
        balls.removeAll()
        
        // Initial setup: one small (light), one large (heavy)
        let ballSmall = Ball(
            id: UUID(),
            position: CGPoint(x: 100, y: 150),
            velocity: .zero,
            radius: 24, // small diameter = 48
            mass: 1.2,
            rollingFriction: 0.05
        )
        
        let ballLarge = Ball(
            id: UUID(),
            position: CGPoint(x: 220, y: 350),
            velocity: .zero,
            radius: 54, // large diameter = 108
            mass: 10.0,
            rollingFriction: 0.05
        )
        
        self.balls = [ballSmall, ballLarge]
    }
    
    func start() {
        guard displayLink == nil else { return }
        lastTimestamp = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func step(displayLink: CADisplayLink) {
        let currentTimestamp = displayLink.timestamp
        var dt = currentTimestamp - lastTimestamp
        
        // Guard against spikes (e.g. app backgrounding)
        if dt <= 0 || dt > 0.1 {
            dt = 1.0 / 60.0
        }
        lastTimestamp = currentTimestamp
        
        updatePhysics(dt: CGFloat(dt))
    }
    
    // MARK: - Drag Gesture Controls
    
    func startDragging(ballId: UUID, touchPos: CGPoint) {
        draggedBallId = ballId
        dragTouchPos = touchPos
    }
    
    func updateDragging(touchPos: CGPoint) {
        dragTouchPos = touchPos
    }
    
    func stopDragging() {
        draggedBallId = nil
    }
    
    // MARK: - Spawn and Clean
    
    func summonBall(mass: CGFloat, size: CGFloat, rollingFriction: CGFloat) {
        let radius = size / 2.0
        
        // Default to center if bounds are zero
        let spawnX = bounds.width > 0 ? bounds.width / 2.0 : 180.0
        let spawnY = bounds.height > 0 ? bounds.height / 2.0 : 350.0
        
        // Add subtle random jitter to spawn coordinates to avoid overlapping stacking
        let jitterX = CGFloat.random(in: -10...10)
        let jitterY = CGFloat.random(in: -10...10)
        
        let newBall = Ball(
            id: UUID(),
            position: CGPoint(x: spawnX + jitterX, y: spawnY + jitterY),
            velocity: .zero,
            radius: radius,
            mass: mass,
            rollingFriction: rollingFriction
        )
        
        balls.append(newBall)
    }
    
    func deleteAllBalls() {
        balls.removeAll()
    }
    
    // MARK: - Ball Color Mapping
    
    /// Maps density (mass/radius) to grayscale value in the range [0.0 (darkest/heaviest) ... 0.8 (lightest)].
    func colorForBall(_ ball: Ball) -> Color {
        guard !balls.isEmpty else { return .gray }
        
        let densities = balls.map { $0.density }
        let currentMin = densities.min() ?? 0.05
        let currentMax = densities.max() ?? 0.5
        
        // Seed default range for smooth rendering if there is only one ball or identical balls
        let refMin = min(currentMin, 0.05)
        let refMax = max(currentMax, 0.4)
        
        let range = refMax - refMin
        let normalized: CGFloat
        if range > 0.001 {
            normalized = (ball.density - refMin) / range
        } else {
            normalized = 0.5
        }
        
        // Clamping normalized value to [0, 1]
        let clampedNormalized = min(max(normalized, 0.0), 1.0)
        
        // Density to Grayscale (high density -> dark, low density -> light)
        let grayVal = 0.8 - Double(clampedNormalized) * 0.8
        let safeGray = min(max(grayVal, 0.0), 0.8)
        
        return Color(white: safeGray)
    }
    
    // MARK: - Internal Physics Updates
    
    private func adjustBallsToBounds() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        for i in 0..<balls.count {
            var b = balls[i]
            let minX = b.radius
            let maxX = bounds.width - b.radius
            let minY = b.radius
            let maxY = bounds.height - b.radius
            
            b.position.x = min(max(b.position.x, minX), maxX)
            b.position.y = min(max(b.position.y, minY), maxY)
            balls[i] = b
        }
    }
    
    private func updatePhysics(dt: CGFloat) {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        
        let gravityVector = MotionManager.shared.gravity
        var maxCollisionImpulse: CGFloat = 0.0
        
        // Drag details for haptic modulation
        var maxDragForceMagnitude: CGFloat = 0.0
        var draggingBallMass: CGFloat = 1.0
        
        // 1. Position and Velocity Integrations
        for i in 0..<balls.count {
            var ball = balls[i]
            
            // Gravity force acceleration
            let aGravityX = gravityVector.dx * gravityMultiplier
            let aGravityY = gravityVector.dy * gravityMultiplier
            
            // Drag spring force acceleration
            var aDragX: CGFloat = 0.0
            var aDragY: CGFloat = 0.0
            
            if ball.id == draggedBallId {
                let dx = dragTouchPos.x - ball.position.x
                let dy = dragTouchPos.y - ball.position.y
                
                // Spring force F = K * displacement
                let forceX = springStiffness * dx
                let forceY = springStiffness * dy
                
                let forceMag = sqrt(forceX * forceX + forceY * forceY)
                if forceMag > maxDragForceMagnitude {
                    maxDragForceMagnitude = forceMag
                    draggingBallMass = ball.mass
                }
                
                // a = F / m
                aDragX = forceX / ball.mass
                aDragY = forceY / ball.mass
                
                // Apply spring damping directly to velocity to prevent infinite jitter
                aDragX -= springDamping * ball.velocity.dx
                aDragY -= springDamping * ball.velocity.dy
            }
            
            let aActiveX = aGravityX + aDragX
            let aActiveY = aGravityY + aDragY
            let activeAccMag = sqrt(aActiveX * aActiveX + aActiveY * aActiveY)
            
            // Rolling Friction
            let combinedFrictionCoef = planeFriction + ball.rollingFriction
            let frictionDecelLimit = combinedFrictionCoef * baseFrictionDecel
            
            let speed = sqrt(ball.velocity.dx * ball.velocity.dx + ball.velocity.dy * ball.velocity.dy)
            
            if speed < 2.5 && ball.id != draggedBallId {
                // Ball is static/near-static: check static friction threshold
                if activeAccMag <= frictionDecelLimit {
                    ball.velocity = .zero
                } else {
                    // Start rolling: subtract static friction threshold
                    let ratio = frictionDecelLimit / activeAccMag
                    let aNetX = aActiveX - (aActiveX * ratio)
                    let aNetY = aActiveY - (aActiveY * ratio)
                    
                    ball.velocity.dx += aNetX * dt
                    ball.velocity.dy += aNetY * dt
                }
            } else {
                // Ball is rolling: apply sliding friction opposite to velocity direction
                let fx = -ball.velocity.dx / (speed > 0 ? speed : 1.0)
                let fy = -ball.velocity.dy / (speed > 0 ? speed : 1.0)
                
                let aFrictionX = fx * frictionDecelLimit
                let aFrictionY = fy * frictionDecelLimit
                
                let aNetX = aActiveX + aFrictionX
                let aNetY = aActiveY + aFrictionY
                
                let nextVx = ball.velocity.dx + aNetX * dt
                let nextVy = ball.velocity.dy + aNetY * dt
                
                // Clamp velocity to zero if friction would reverse direction in this step
                if (nextVx * ball.velocity.dx < 0) && (abs(aFrictionX) > abs(aActiveX)) {
                    ball.velocity.dx = 0
                } else {
                    ball.velocity.dx = nextVx
                }
                
                if (nextVy * ball.velocity.dy < 0) && (abs(aFrictionY) > abs(aActiveY)) {
                    ball.velocity.dy = 0
                } else {
                    ball.velocity.dy = nextVy
                }
            }
            
            // Euler-Cromer Integration
            ball.position.x += ball.velocity.dx * dt
            ball.position.y += ball.velocity.dy * dt
            
            balls[i] = ball
        }
        
        // 2. Ball-to-Ball Collisions
        // Run collision solver twice to improve stability in multi-ball overlap scenarios
        for _ in 0..<2 {
            for i in 0..<balls.count {
                for j in (i+1)..<balls.count {
                    let b1 = balls[i]
                    let b2 = balls[j]
                    
                    let dx = b2.position.x - b1.position.x
                    let dy = b2.position.y - b1.position.y
                    let dist = sqrt(dx*dx + dy*dy)
                    let sumRadii = b1.radius + b2.radius
                    
                    if dist < sumRadii {
                        // Collide! Normal vector
                        let nx = dx / (dist > 0 ? dist : 1.0)
                        let ny = dy / (dist > 0 ? dist : 1.0)
                        let overlap = sumRadii - dist
                        
                        // Push apart proportional to inverse mass
                        let totalInvMass = (1.0 / b1.mass) + (1.0 / b2.mass)
                        
                        balls[i].position.x -= nx * overlap * ((1.0 / b1.mass) / totalInvMass)
                        balls[i].position.y -= ny * overlap * ((1.0 / b1.mass) / totalInvMass)
                        
                        balls[j].position.x += nx * overlap * ((1.0 / b2.mass) / totalInvMass)
                        balls[j].position.y += ny * overlap * ((1.0 / b2.mass) / totalInvMass)
                        
                        // Recalculate relative velocities
                        let rvx = balls[j].velocity.dx - balls[i].velocity.dx
                        let rvy = balls[j].velocity.dy - balls[i].velocity.dy
                        let relativeVelNormal = rvx * nx + rvy * ny
                        
                        if relativeVelNormal < 0 {
                            // Elastic collision velocity exchange
                            let bouncinessCoef = edgeBounciness // Match screen borders for simplicity
                            let impulse = -(1.0 + bouncinessCoef) * relativeVelNormal / totalInvMass
                            
                            balls[i].velocity.dx -= (impulse / b1.mass) * nx
                            balls[i].velocity.dy -= (impulse / b1.mass) * ny
                            
                            balls[j].velocity.dx += (impulse / b2.mass) * nx
                            balls[j].velocity.dy += (impulse / b2.mass) * ny
                            
                            // Only trigger haptic and sound for significant impact speed
                            if abs(relativeVelNormal) > 35.0 && impulse > maxCollisionImpulse {
                                maxCollisionImpulse = impulse
                                
                                // Synthesize dynamic physical impact sound
                                SoundManager.shared.playCollision(
                                    mass: min(b1.mass, b2.mass),
                                    size: min(b1.radius, b2.radius) * 2.0,
                                    bounciness: edgeBounciness,
                                    impulse: impulse
                                )
                            }
                        }
                    }
                }
            }
        }
        
        // 3. Border/Edge Collisions
        for i in 0..<balls.count {
            var b = balls[i]
            
            // Left boundary
            if b.position.x - b.radius < 0 {
                b.position.x = b.radius
                let normalVel = b.velocity.dx
                if normalVel < 0 {
                    b.velocity.dx = -normalVel * edgeBounciness
                    if abs(normalVel) > 35.0 {
                        let impulse = b.mass * (1.0 + edgeBounciness) * abs(normalVel)
                        if impulse > maxCollisionImpulse {
                            maxCollisionImpulse = impulse
                        }
                        SoundManager.shared.playCollision(
                            mass: b.mass,
                            size: b.radius * 2.0,
                            bounciness: edgeBounciness,
                            impulse: impulse
                        )
                    }
                }
            }
            
            // Right boundary
            if b.position.x + b.radius > bounds.width {
                b.position.x = bounds.width - b.radius
                let normalVel = b.velocity.dx
                if normalVel > 0 {
                    b.velocity.dx = -normalVel * edgeBounciness
                    if abs(normalVel) > 35.0 {
                        let impulse = b.mass * (1.0 + edgeBounciness) * abs(normalVel)
                        if impulse > maxCollisionImpulse {
                            maxCollisionImpulse = impulse
                        }
                        SoundManager.shared.playCollision(
                            mass: b.mass,
                            size: b.radius * 2.0,
                            bounciness: edgeBounciness,
                            impulse: impulse
                        )
                    }
                }
            }
            
            // Top boundary
            if b.position.y - b.radius < 0 {
                b.position.y = b.radius
                let normalVel = b.velocity.dy
                if normalVel < 0 {
                    b.velocity.dy = -normalVel * edgeBounciness
                    if abs(normalVel) > 35.0 {
                        let impulse = b.mass * (1.0 + edgeBounciness) * abs(normalVel)
                        if impulse > maxCollisionImpulse {
                            maxCollisionImpulse = impulse
                        }
                        SoundManager.shared.playCollision(
                            mass: b.mass,
                            size: b.radius * 2.0,
                            bounciness: edgeBounciness,
                            impulse: impulse
                        )
                    }
                }
            }
            
            // Bottom boundary
            if b.position.y + b.radius > bounds.height {
                b.position.y = bounds.height - b.radius
                let normalVel = b.velocity.dy
                if normalVel > 0 {
                    b.velocity.dy = -normalVel * edgeBounciness
                    if abs(normalVel) > 35.0 {
                        let impulse = b.mass * (1.0 + edgeBounciness) * abs(normalVel)
                        if impulse > maxCollisionImpulse {
                            maxCollisionImpulse = impulse
                        }
                        SoundManager.shared.playCollision(
                            mass: b.mass,
                            size: b.radius * 2.0,
                            bounciness: edgeBounciness,
                            impulse: impulse
                        )
                    }
                }
            }
            
            balls[i] = b
        }
        
        // 4. Modulate Haptic Feedback Triggers
        
        // Collision Trigger: play a sharp buzz/thud haptic based on impact force
        if maxCollisionImpulse > 60.0 {
            // Normalize impulse with a typical upper reference value of 800.0
            let refImpulse: CGFloat = 800.0
            let intensity = Float(min(maxCollisionImpulse / refImpulse, 1.0))
            
            // Sharpness scale [0.3 - 1.0] based on intensity of the bump
            let sharpness = Float(0.3 + 0.7 * Double(intensity))
            
            HapticManager.shared.playCollisionHaptic(intensity: intensity, sharpness: sharpness)
        }
        
        // Movement/Drag Hum Trigger: continuous feedback
        if draggedBallId != nil && maxDragForceMagnitude > 0 {
            // Dragging: intensity modulated by drag stretch force and mass
            let refDragForce: CGFloat = 1000.0
            let forceRatio = min(maxDragForceMagnitude / refDragForce, 1.0)
            
            // Mass weight factor (0.1 to 1.0)
            let massRatio = min(draggingBallMass / 10.0, 1.0)
            let intensity = Float(0.08 + 0.82 * forceRatio * (0.3 + 0.7 * massRatio))
            let sharpness = Float(0.1 + 0.6 * forceRatio)
            
            HapticManager.shared.startContinuousHaptic(intensity: intensity, sharpness: sharpness)
        } else {
            // Check rolling kinetic energy for rolling hum
            var totalKE: CGFloat = 0.0
            for b in balls {
                let speedSq = b.velocity.dx * b.velocity.dx + b.velocity.dy * b.velocity.dy
                totalKE += 0.5 * b.mass * speedSq
            }
            
            if totalKE > 400.0 {
                // Map rolling energy to very gentle hum
                let refKE: CGFloat = 100000.0
                let energyRatio = min(totalKE / refKE, 1.0)
                let intensity = Float(0.02 + 0.12 * energyRatio)
                let sharpness = Float(0.05 + 0.1 * energyRatio)
                
                HapticManager.shared.startContinuousHaptic(intensity: intensity, sharpness: sharpness)
            } else {
                HapticManager.shared.stopContinuousHaptic()
            }
        }
        
        // 5. Update Procedural Rolling Friction Sounds
        let rollingStates = balls.compactMap { ball -> (id: UUID, mass: CGFloat, speed: CGFloat)? in
            guard ball.id != draggedBallId else { return nil }
            let speed = sqrt(ball.velocity.dx * ball.velocity.dx + ball.velocity.dy * ball.velocity.dy)
            guard speed > 5.0 else { return nil }
            return (id: ball.id, mass: ball.mass, speed: speed)
        }
        SoundManager.shared.updateRollingVoices(activeRolls: rollingStates)
    }
}
