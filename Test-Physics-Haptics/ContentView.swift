//
//  ContentView.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var physicsEngine = PhysicsEngine()
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var showSettings = false
    @State private var showSummon = false
    
    // Core motion gravity vector reference for dynamic shadows
    @ObservedObject private var motionManager = MotionManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .padding(12)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Text("Physics & Haptics")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(Color(white: 0.2))
                
                Spacer()
                
                Button {
                    showSummon = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .padding(12)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Color.white)
            
            // Physics Sandbox Canvas
            GeometryReader { geometry in
                ZStack {
                    // Subtle blueprint/draft grid for spatial speed perspective
                    GridBackgroundView()
                    
                    // Rubberband spring connector line when dragging
                    if let draggedId = physicsEngine.draggedBallId,
                       let draggedBall = physicsEngine.balls.first(where: { $0.id == draggedId }) {
                        RubberbandLine(from: draggedBall.position, to: physicsEngine.dragTouchPos)
                    }
                    
                    // Render individual balls
                    ForEach(physicsEngine.balls) { ball in
                        BallView(
                            ball: ball,
                            color: physicsEngine.colorForBall(ball),
                            gravity: motionManager.gravity
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("SimulationContainer"))
                                .onChanged { value in
                                    if physicsEngine.draggedBallId != ball.id {
                                        physicsEngine.startDragging(ballId: ball.id, touchPos: value.location)
                                    } else {
                                        physicsEngine.updateDragging(touchPos: value.location)
                                    }
                                }
                                .onEnded { _ in
                                    physicsEngine.stopDragging()
                                }
                        )
                    }
                }
                .background(Color(white: 0.98)) // minimalist white/off-white background
                .coordinateSpace(name: "SimulationContainer")
                .onAppear {
                    physicsEngine.bounds = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    physicsEngine.bounds = newSize
                }
            }
            .clipped()
        }
        .onAppear {
            physicsEngine.start()
            motionManager.start()
        }
        .onDisappear {
            physicsEngine.stop()
            motionManager.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                physicsEngine.start()
                motionManager.start()
            case .inactive, .background:
                physicsEngine.stop()
                motionManager.stop()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: physicsEngine)
        }
        .sheet(isPresented: $showSummon) {
            SummonSheet(engine: physicsEngine)
        }
    }
}

// MARK: - Secondary Views & Components

struct GridBackgroundView: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let spacing: CGFloat = 36.0
                
                // Draw vertical lines
                var x: CGFloat = 0
                while x < geometry.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    x += spacing
                }
                
                // Draw horizontal lines
                var y: CGFloat = 0
                while y < geometry.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    y += spacing
                }
            }
            .stroke(Color(white: 0.93), lineWidth: 1.0)
        }
    }
}

struct RubberbandLine: View {
    var from: CGPoint
    var to: CGPoint
    
    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            Color.gray.opacity(0.35),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4])
        )
    }
}

struct BallView: View {
    let ball: Ball
    let color: Color
    let gravity: CGVector
    
    var body: some View {
        Circle()
            .fill(color)
            // Radial highlight on top-left of circle to present it as a 3D sphere
            .overlay(
                RadialGradient(
                    gradient: Gradient(colors: [.white.opacity(0.45), .clear]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: ball.radius
                )
            )
            .frame(width: ball.radius * 2, height: ball.radius * 2)
            // Offset shadow opposite of tilt gravity direction to reinforce depth
            .shadow(
                color: Color.black.opacity(0.18),
                radius: 6.0,
                x: -gravity.dx * 7.0,
                y: -gravity.dy * 7.0
            )
            .position(ball.position)
    }
}

// MARK: - Popup Sheets

struct SettingsSheet: View {
    @ObservedObject var engine: PhysicsEngine
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Plane Settings")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Plane Friction")
                            Spacer()
                            Text(String(format: "%.2f", engine.planeFriction))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $engine.planeFriction, in: 0.0...1.0, step: 0.05)
                        Text("Higher values decelerate balls, making high-friction balls static / sticky.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Edge Bounciness")
                            Spacer()
                            Text(String(format: "%.2f", engine.edgeBounciness))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $engine.edgeBounciness, in: 0.0...1.0, step: 0.05)
                        Text("Coefficient of restitution for edge boundaries and ball-to-ball impacts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        engine.deleteAllBalls()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete All Balls")
                            Spacer()
                        }
                    }
                    
                    Button {
                        engine.setupInitialBalls()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reset to Defaults")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Configure Sandbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SummonSheet: View {
    @ObservedObject var engine: PhysicsEngine
    @Environment(\.dismiss) var dismiss
    
    @State private var mass: Double = 2.0
    @State private var size: Double = 80.0 // Diameter
    @State private var rollingFriction: Double = 0.05
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Ball Specs")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Size (Diameter)")
                            Spacer()
                            Text("\(Int(size)) pt")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $size, in: 24.0...160.0, step: 4.0)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Mass (Weight)")
                            Spacer()
                            Text(String(format: "%.1f kg", mass))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $mass, in: 0.2...20.0, step: 0.2)
                        Text("Heavier masses create slower rubberband responses and drag vibrations.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Rolling Friction")
                            Spacer()
                            Text(String(format: "%.2f", rollingFriction))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $rollingFriction, in: 0.0...1.0, step: 0.05)
                        Text("Friction coefficient. High friction prevents rolling under slight tilts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Visual Preview")) {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            let radius = size / 2.0
                            let density = mass / radius
                            
                            // Color mapping logic matched dynamically
                            let densities = engine.balls.map { $0.density } + [density]
                            let minD = densities.min() ?? 0.05
                            let maxD = densities.max() ?? 0.5
                            let refMin = min(minD, 0.05)
                            let refMax = max(maxD, 0.4)
                            let range = refMax - refMin
                            let t = range > 0.001 ? (density - refMin) / range : 0.5
                            let clampedT = min(max(t, 0.0), 1.0)
                            let grayVal = 0.8 - clampedT * 0.8
                            
                            Circle()
                                .fill(Color(white: grayVal))
                                .overlay(
                                    RadialGradient(
                                        gradient: Gradient(colors: [.white.opacity(0.45), .clear]),
                                        center: .topLeading,
                                        startRadius: 0,
                                        endRadius: radius
                                    )
                                )
                                .frame(width: size, height: size)
                                .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 3)
                            
                            Text("Normalized Density Shade")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                
                Section {
                    Button {
                        engine.summonBall(
                            mass: CGFloat(mass),
                            size: CGFloat(size),
                            rollingFriction: CGFloat(rollingFriction)
                        )
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Summon Ball")
                                .font(.headline)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Summon a Ball")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

