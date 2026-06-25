//
//  PhysicsEngine.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import Foundation
import CoreGraphics

struct Ball: Identifiable, Equatable {
    let id: UUID
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var mass: CGFloat
    var rollingFriction: CGFloat // Ball-specific friction coefficient
    var bounciness: CGFloat      // Ball-specific bounciness (restitution)
    
    // Normalized density = mass / radius
    var density: CGFloat {
        return mass / radius
    }
}

struct CollisionEvent {
    let mass: CGFloat
    let size: CGFloat
    let bounciness: CGFloat
    let impulse: CGFloat
}

struct PhysicsStepResult {
    let collisions: [CollisionEvent]
    let maxCollisionImpulse: CGFloat
    let maxDragForceMagnitude: CGFloat
    let draggingBallMass: CGFloat
    let activeRolls: [(id: UUID, mass: CGFloat, speed: CGFloat, bounciness: CGFloat)]
}

class PhysicsEngine {
    var balls: [Ball] = []
    
    // Simulation parameters
    var planeFriction: CGFloat = 0.15 // Plane rolling friction coef
    var edgeBounciness: CGFloat = 0.75 // Border bounciness (restitution)
    var isGravityEnabled: Bool = true
    var isDirectFollow: Bool = false
    
    // Bounds of the simulation view, updated externally
    var bounds: CGSize = .zero {
        didSet {
            adjustBallsToBounds()
        }
    }
    
    // Tracking active drag gesture
    var draggedBallId: UUID?
    var dragTouchPos: CGPoint = .zero
    
    // Physical Constants
    var gravityMultiplier: CGFloat = 1100.0 // Pixels/s^2 multiplier for tilt gravity
    private let springStiffness: CGFloat = 20.0     // Spring constant (K) for rubberband drag
    private let springDamping: CGFloat = 4.0       // Damping constant (C) for rubberband drag
    private let baseFrictionDecel: CGFloat = 160.0 // Base deceleration for rolling friction
    
    init() {
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
            rollingFriction: 0.05,
            bounciness: 0.6
        )
        
        let ballLarge = Ball(
            id: UUID(),
            position: CGPoint(x: 220, y: 350),
            velocity: .zero,
            radius: 54, // large diameter = 108
            mass: 10.0,
            rollingFriction: 0.05,
            bounciness: 0.5
        )
        
        self.balls = [ballSmall, ballLarge]
    }
    
    func adjustBallsToBounds() {
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
    
    func summonBall(mass: CGFloat, size: CGFloat, rollingFriction: CGFloat, bounciness: CGFloat) {
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
            rollingFriction: rollingFriction,
            bounciness: bounciness
        )
        
        balls.append(newBall)
    }
    
    func deleteAllBalls() {
        balls.removeAll()
    }
    
    // MARK: - Internal Physics Updates
    
    func updatePhysics(dt: CGFloat, gravityVector: CGVector) -> PhysicsStepResult {
        guard bounds.width > 0 && bounds.height > 0 else {
            return PhysicsStepResult(
                collisions: [],
                maxCollisionImpulse: 0.0,
                maxDragForceMagnitude: 0.0,
                draggingBallMass: 1.0,
                activeRolls: []
            )
        }
        
        var collisions: [CollisionEvent] = []
        var maxCollisionImpulse: CGFloat = 0.0
        
        // Drag details for haptic modulation
        var maxDragForceMagnitude: CGFloat = 0.0
        var draggingBallMass: CGFloat = 1.0
        
        // 1. Position and Velocity Integrations
        for i in 0..<balls.count {
            var ball = balls[i]
            
            // Gravity force acceleration
            let currentGravity = isGravityEnabled ? gravityVector : .zero
            let aGravityX = currentGravity.dx * gravityMultiplier
            let aGravityY = currentGravity.dy * gravityMultiplier
            
            // Drag spring force acceleration
            var aDragX: CGFloat = 0.0
            var aDragY: CGFloat = 0.0
            
            if ball.id == draggedBallId {
                if isDirectFollow {
                    // Direct follow: calculate velocity from displacement, then snap position
                    let vx = (dragTouchPos.x - ball.position.x) / dt
                    let vy = (dragTouchPos.y - ball.position.y) / dt
                    
                    // Clamp velocity to a safe maximum to prevent extreme impulses on release
                    let maxVelocity: CGFloat = 3000.0
                    let speed = sqrt(vx * vx + vy * vy)
                    if speed > maxVelocity {
                        ball.velocity = CGVector(dx: vx / speed * maxVelocity, dy: vy / speed * maxVelocity)
                    } else {
                        ball.velocity = CGVector(dx: vx, dy: vy)
                    }
                    
                    ball.position = dragTouchPos
                } else {
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
            }
            
            let aActiveX = aGravityX + aDragX
            let aActiveY = aGravityY + aDragY
            let activeAccMag = sqrt(aActiveX * aActiveX + aActiveY * aActiveY)
            
            // Rolling Friction
            let combinedFrictionCoef = planeFriction + ball.rollingFriction
            let frictionDecelLimit = combinedFrictionCoef * baseFrictionDecel
            
            let speed = sqrt(ball.velocity.dx * ball.velocity.dx + ball.velocity.dy * ball.velocity.dy)
            
            if ball.id == draggedBallId && isDirectFollow {
                // Skip friction and integration for direct follow
                balls[i] = ball
                continue
            }
            
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
        
        // 2. Unified Collision Solver Loop (Ball-to-Ball and Border/Edge)
        // Run the combined solver 4 times to let positions and velocities converge globally,
        // avoiding constraint fights and jitter in resting contacts (especially in corners).
        let solverIterations = 4
        for iteration in 0..<solverIterations {
            // A. Ball-to-Ball Collisions
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
                        
                        // Push apart proportional to inverse mass with slop (allowed penetration) to prevent jitter
                        let slop: CGFloat = 0.25
                        let correctAmount = max(0.0, overlap - slop) * 0.85
                        let totalInvMass = (1.0 / b1.mass) + (1.0 / b2.mass)
                        
                        if correctAmount > 0.0 {
                            balls[i].position.x -= nx * correctAmount * ((1.0 / b1.mass) / totalInvMass)
                            balls[i].position.y -= ny * correctAmount * ((1.0 / b1.mass) / totalInvMass)
                            
                            balls[j].position.x += nx * correctAmount * ((1.0 / b2.mass) / totalInvMass)
                            balls[j].position.y += ny * correctAmount * ((1.0 / b2.mass) / totalInvMass)
                        }
                        
                        // Recalculate relative velocities
                        let rvx = balls[j].velocity.dx - balls[i].velocity.dx
                        let rvy = balls[j].velocity.dy - balls[i].velocity.dy
                        let relativeVelNormal = rvx * nx + rvy * ny
                        
                        let restingThreshold: CGFloat = 55.0
                        
                        if relativeVelNormal < 0 {
                            // Apply inelastic threshold of 55 px/s to prevent infinite micro-bounces (resting jitter)
                            let coef = abs(relativeVelNormal) < restingThreshold ? 0.0 : (b1.bounciness + b2.bounciness) / 2.0
                            let impulse = -(1.0 + coef) * relativeVelNormal / totalInvMass
                            
                            balls[i].velocity.dx -= (impulse / b1.mass) * nx
                            balls[i].velocity.dy -= (impulse / b1.mass) * ny
                            
                            balls[j].velocity.dx += (impulse / b2.mass) * nx
                            balls[j].velocity.dy += (impulse / b2.mass) * ny
                            
                            // Only trigger haptic and sound for significant impact speed on the first iteration
                            if iteration == 0 && abs(relativeVelNormal) > restingThreshold {
                                if impulse > maxCollisionImpulse {
                                    maxCollisionImpulse = impulse
                                }
                                
                                collisions.append(CollisionEvent(
                                    mass: min(b1.mass, b2.mass),
                                    size: min(b1.radius, b2.radius) * 2.0,
                                    bounciness: coef,
                                    impulse: impulse
                                ))
                            }
                        }
                    }
                }
            }
            
            // B. Border/Edge Collisions
            for i in 0..<balls.count {
                var b = balls[i]
                let restingThreshold: CGFloat = 55.0
                
                // Left boundary
                if b.position.x - b.radius < 0 {
                    b.position.x = b.radius
                    let normalVel = b.velocity.dx
                    if normalVel < 0 {
                        let coef = abs(normalVel) < restingThreshold ? 0.0 : (b.bounciness + edgeBounciness) / 2.0
                        b.velocity.dx = -normalVel * coef
                        if iteration == 0 && abs(normalVel) > restingThreshold {
                            let impulse = b.mass * (1.0 + coef) * abs(normalVel)
                            if impulse > maxCollisionImpulse {
                                maxCollisionImpulse = impulse
                            }
                            collisions.append(CollisionEvent(
                                mass: b.mass,
                                size: b.radius * 2.0,
                                bounciness: coef,
                                impulse: impulse
                            ))
                        }
                    }
                }
                
                // Right boundary
                if b.position.x + b.radius > bounds.width {
                    b.position.x = bounds.width - b.radius
                    let normalVel = b.velocity.dx
                    if normalVel > 0 {
                        let coef = abs(normalVel) < restingThreshold ? 0.0 : (b.bounciness + edgeBounciness) / 2.0
                        b.velocity.dx = -normalVel * coef
                        if iteration == 0 && abs(normalVel) > restingThreshold {
                            let impulse = b.mass * (1.0 + coef) * abs(normalVel)
                            if impulse > maxCollisionImpulse {
                                maxCollisionImpulse = impulse
                            }
                            collisions.append(CollisionEvent(
                                mass: b.mass,
                                size: b.radius * 2.0,
                                bounciness: coef,
                                impulse: impulse
                            ))
                        }
                    }
                }
                
                // Top boundary
                if b.position.y - b.radius < 0 {
                    b.position.y = b.radius
                    let normalVel = b.velocity.dy
                    if normalVel < 0 {
                        let coef = abs(normalVel) < restingThreshold ? 0.0 : (b.bounciness + edgeBounciness) / 2.0
                        b.velocity.dy = -normalVel * coef
                        if iteration == 0 && abs(normalVel) > restingThreshold {
                            let impulse = b.mass * (1.0 + coef) * abs(normalVel)
                            if impulse > maxCollisionImpulse {
                                maxCollisionImpulse = impulse
                            }
                            collisions.append(CollisionEvent(
                                mass: b.mass,
                                size: b.radius * 2.0,
                                bounciness: coef,
                                impulse: impulse
                            ))
                        }
                    }
                }
                
                // Bottom boundary
                if b.position.y + b.radius > bounds.height {
                    b.position.y = bounds.height - b.radius
                    let normalVel = b.velocity.dy
                    if normalVel > 0 {
                        let coef = abs(normalVel) < restingThreshold ? 0.0 : (b.bounciness + edgeBounciness) / 2.0
                        b.velocity.dy = -normalVel * coef
                        if iteration == 0 && abs(normalVel) > restingThreshold {
                            let impulse = b.mass * (1.0 + coef) * abs(normalVel)
                            if impulse > maxCollisionImpulse {
                                maxCollisionImpulse = impulse
                            }
                            collisions.append(CollisionEvent(
                                mass: b.mass,
                                size: b.radius * 2.0,
                                bounciness: coef,
                                impulse: impulse
                            ))
                        }
                    }
                }
                
                balls[i] = b
            }
        }
        
        // Find rolling active states
        let rollingStates = balls.compactMap { ball -> (id: UUID, mass: CGFloat, speed: CGFloat, bounciness: CGFloat)? in
            guard ball.id != draggedBallId else { return nil }
            let speed = sqrt(ball.velocity.dx * ball.velocity.dx + ball.velocity.dy * ball.velocity.dy)
            guard speed > 5.0 else { return nil }
            return (id: ball.id, mass: ball.mass, speed: speed, bounciness: ball.bounciness)
        }
        
        return PhysicsStepResult(
            collisions: collisions,
            maxCollisionImpulse: maxCollisionImpulse,
            maxDragForceMagnitude: maxDragForceMagnitude,
            draggingBallMass: draggingBallMass,
            activeRolls: rollingStates
        )
    }
}
