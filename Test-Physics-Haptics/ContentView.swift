//
//  ContentView.swift
//  Test-Physics-Haptics
//
//  Created by Antigravity on 25/06/26.
//

import SwiftUI
import Combine

// MARK: - ViewModel

class SandboxViewModel: ObservableObject {
    @Published var balls: [Ball] = []
    
    @Published var planeFriction: CGFloat = 0.15 {
        didSet {
            physicsEngine.planeFriction = planeFriction
        }
    }
    
    @Published var edgeBounciness: CGFloat = 0.75 {
        didSet {
            physicsEngine.edgeBounciness = edgeBounciness
        }
    }
    
    @Published var isGravityEnabled: Bool = true {
        didSet {
            physicsEngine.isGravityEnabled = isGravityEnabled
        }
    }
    
    @Published var gravityMultiplier: CGFloat = 1100.0 {
        didSet {
            physicsEngine.gravityMultiplier = gravityMultiplier
        }
    }
    
    @Published var isDirectFollow: Bool = false {
        didSet {
            physicsEngine.isDirectFollow = isDirectFollow
        }
    }
    
    @Published var isAxisLocked: Bool = false {
        didSet {
            MotionManager.shared.isAxisLocked = isAxisLocked
        }
    }
    
    @Published var isSoundEnabled: Bool = true {
        didSet {
            SoundManager.shared.isSoundEnabled = isSoundEnabled
        }
    }
    
    @Published var isRollingSoundEnabled: Bool = true {
        didSet {
            SoundManager.shared.isRollingSoundEnabled = isRollingSoundEnabled
        }
    }
    
    @Published var masterVolume: Double = 1.0 {
        didSet {
            SoundManager.shared.masterVolume = Float(masterVolume)
        }
    }
    
    @Published var gravity: CGVector = .zero
    
    var draggedBallId: UUID? {
        physicsEngine.draggedBallId
    }
    
    var dragTouchPos: CGPoint {
        physicsEngine.dragTouchPos
    }
    
    private let physicsEngine = PhysicsEngine()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var dragStartDate: Date?
    private var undoStack: [[Ball]] = []
    private var redoStack: [[Ball]] = []
    
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    
    init() {
        // Load initial states from Singletons
        self.isAxisLocked = MotionManager.shared.isAxisLocked
        self.isSoundEnabled = SoundManager.shared.isSoundEnabled
        self.isRollingSoundEnabled = SoundManager.shared.isRollingSoundEnabled
        self.masterVolume = Double(SoundManager.shared.masterVolume)
        
        // Sync balls initial state
        self.balls = physicsEngine.balls
        
        // Bind gravity from MotionManager to the ViewModel
        MotionManager.shared.$gravity
            .receive(on: RunLoop.main)
            .sink { [weak self] newGravity in
                self?.gravity = newGravity
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Simulation Loop
    
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
        
        if dt <= 0 || dt > 0.1 {
            dt = 1.0 / 60.0
        }
        lastTimestamp = currentTimestamp
        
        // Update direct follow timing
        if let startDate = dragStartDate {
            let elapsed = Date().timeIntervalSince(startDate)
            if elapsed >= 3.0 && !isDirectFollow {
                isDirectFollow = true
                // Trigger subtle engagement haptic thud
                HapticManager.shared.playCollisionHaptic(intensity: 0.5, sharpness: 0.85)
            }
        }
        
        let result = physicsEngine.updatePhysics(dt: CGFloat(dt), gravityVector: gravity)
        
        // 1. Handle collision audio side-effects
        for collision in result.collisions {
            SoundManager.shared.playCollision(
                mass: collision.mass,
                size: collision.size,
                bounciness: collision.bounciness,
                impulse: collision.impulse
            )
        }
        
        // 2. Handle haptic feedback triggers
        if result.maxCollisionImpulse > 60.0 {
            let refImpulse: CGFloat = 800.0
            let intensity = Float(min(result.maxCollisionImpulse / refImpulse, 1.0))
            let sharpness = Float(0.3 + 0.7 * Double(intensity))
            HapticManager.shared.playCollisionHaptic(intensity: intensity, sharpness: sharpness)
        }
        
        if physicsEngine.draggedBallId != nil && result.maxDragForceMagnitude > 0 {
            let refDragForce: CGFloat = 1000.0
            let forceRatio = min(result.maxDragForceMagnitude / refDragForce, 1.0)
            let massRatio = min(result.draggingBallMass / 10.0, 1.0)
            let intensity = Float(0.08 + 0.82 * forceRatio * (0.3 + 0.7 * massRatio))
            let sharpness = Float(0.1 + 0.6 * forceRatio)
            HapticManager.shared.startContinuousHaptic(intensity: intensity, sharpness: sharpness)
        } else {
            var totalKE: CGFloat = 0.0
            for b in physicsEngine.balls {
                let speedSq = b.velocity.dx * b.velocity.dx + b.velocity.dy * b.velocity.dy
                totalKE += 0.5 * b.mass * speedSq
            }
            
            if totalKE > 400.0 {
                let refKE: CGFloat = 100000.0
                let energyRatio = min(totalKE / refKE, 1.0)
                let intensity = Float(0.02 + 0.12 * energyRatio)
                let sharpness = Float(0.05 + 0.1 * energyRatio)
                HapticManager.shared.startContinuousHaptic(intensity: intensity, sharpness: sharpness)
            } else {
                HapticManager.shared.stopContinuousHaptic()
            }
        }
        
        // 3. Handle rolling audio side-effects
        SoundManager.shared.updateRollingVoices(activeRolls: result.activeRolls)
        
        // 4. Update published balls array to trigger view refresh
        self.balls = physicsEngine.balls
    }
    
    // MARK: - Bounds updating
    
    func updateBounds(_ size: CGSize) {
        physicsEngine.bounds = size
        self.balls = physicsEngine.balls
    }
    
    // MARK: - Drag Gesture Controls
    
    func startDragging(ballId: UUID, touchPos: CGPoint) {
        physicsEngine.startDragging(ballId: ballId, touchPos: touchPos)
        dragStartDate = Date()
        isDirectFollow = false
        self.balls = physicsEngine.balls
    }
    
    func updateDragging(touchPos: CGPoint) {
        physicsEngine.updateDragging(touchPos: touchPos)
        self.balls = physicsEngine.balls
    }
    
    func stopDragging() {
        physicsEngine.stopDragging()
        dragStartDate = nil
        isDirectFollow = false
        self.balls = physicsEngine.balls
    }
    
    // MARK: - Undo / Redo History Logic
    
    private func saveToUndoStack() {
        undoStack.append(physicsEngine.balls)
        redoStack.removeAll()
    }
    
    func undo() {
        guard !undoStack.isEmpty else { return }
        redoStack.append(physicsEngine.balls)
        let previous = undoStack.removeLast()
        physicsEngine.balls = previous
        self.balls = previous
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(physicsEngine.balls)
        let next = redoStack.removeLast()
        physicsEngine.balls = next
        self.balls = next
    }
    
    // MARK: - Spawn and Clean APIs
    
    func summonBall(mass: CGFloat, size: CGFloat, rollingFriction: CGFloat, bounciness: CGFloat) {
        saveToUndoStack()
        physicsEngine.summonBall(mass: mass, size: size, rollingFriction: rollingFriction, bounciness: bounciness)
        self.balls = physicsEngine.balls
    }
    
    func deleteAllBalls() {
        saveToUndoStack()
        physicsEngine.deleteAllBalls()
        self.balls = physicsEngine.balls
    }
    
    func resetToDefaults() {
        saveToUndoStack()
        physicsEngine.setupInitialBalls()
        self.balls = physicsEngine.balls
    }
    
    func loadChimePreset() {
        saveToUndoStack()
        
        // Frequencies in kHz for C5, E5, G5, A5, C6 chord
        let frequenciesInkHz: [CGFloat] = [0.52325, 0.65925, 0.78399, 0.88000, 1.04650]
        let sizes: [CGFloat] = [70.0, 62.0, 54.0, 48.0, 42.0]
        
        physicsEngine.balls.removeAll()
        
        let count = frequenciesInkHz.count
        let spawnY = physicsEngine.bounds.height > 0 ? physicsEngine.bounds.height / 2.0 : 350.0
        let totalWidth = physicsEngine.bounds.width > 0 ? physicsEngine.bounds.width : 360.0
        
        for i in 0..<count {
            let freqkHz = frequenciesInkHz[i]
            let freqHz = freqkHz * 1000.0
            
            // Math reversal targeting the exact frequency:
            // f = 75.0 + 750.0 / sqrt(m) => m = (750.0 / (f - 75.0))^2
            let massValue = pow(750.0 / (freqHz - 75.0), 2.0)
            
            // Distribute horizontally
            let fraction = CGFloat(i + 1) / CGFloat(count + 1)
            let spawnX = totalWidth * fraction
            
            let radius = sizes[i] / 2.0
            let newBall = Ball(
                id: UUID(),
                position: CGPoint(x: spawnX, y: spawnY),
                velocity: .zero,
                radius: radius,
                mass: CGFloat(massValue),
                rollingFriction: 0.05,
                bounciness: 0.6
            )
            physicsEngine.balls.append(newBall)
        }
        
        self.balls = physicsEngine.balls
    }
    
    // MARK: - Ball Color Mapping (View utility moved from Model to ViewModel)
    
    func colorForBall(_ ball: Ball) -> Color {
        guard !balls.isEmpty else { return .gray }
        
        let densities = balls.map { $0.density }
        let currentMin = densities.min() ?? 0.05
        let currentMax = densities.max() ?? 0.5
        
        let refMin = min(currentMin, 0.05)
        let refMax = max(currentMax, 0.4)
        
        let range = refMax - refMin
        let normalized: CGFloat
        if range > 0.001 {
            normalized = (ball.density - refMin) / range
        } else {
            normalized = 0.5
        }
        
        let clampedNormalized = min(max(normalized, 0.0), 1.0)
        let grayVal = 0.8 - Double(clampedNormalized) * 0.8
        let safeGray = min(max(grayVal, 0.0), 0.8)
        
        return Color(white: safeGray)
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var viewModel = SandboxViewModel()
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var showSettings = false
    @State private var showSummon = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundColor(.gray)
                        .padding(10)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
                
                Button {
                    viewModel.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body)
                        .foregroundColor(viewModel.canUndo ? .primary : .gray.opacity(0.3))
                        .padding(10)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
                .disabled(!viewModel.canUndo)
                
                Button {
                    viewModel.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.body)
                        .foregroundColor(viewModel.canRedo ? .primary : .gray.opacity(0.3))
                        .padding(10)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
                .disabled(!viewModel.canRedo)
                
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
                    if let draggedId = viewModel.draggedBallId,
                       let draggedBall = viewModel.balls.first(where: { $0.id == draggedId }) {
                        RubberbandLine(from: draggedBall.position, to: viewModel.dragTouchPos)
                    }
                    
                    // Render individual balls
                    ForEach(viewModel.balls) { ball in
                        BallView(
                            ball: ball,
                            color: viewModel.colorForBall(ball),
                            gravity: viewModel.gravity,
                            isDirectFollow: viewModel.draggedBallId == ball.id && viewModel.isDirectFollow
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("SimulationContainer"))
                                .onChanged { value in
                                    if viewModel.draggedBallId != ball.id {
                                        viewModel.startDragging(ballId: ball.id, touchPos: value.location)
                                    } else {
                                        viewModel.updateDragging(touchPos: value.location)
                                    }
                                }
                                .onEnded { _ in
                                    viewModel.stopDragging()
                                }
                        )
                    }
                }
                .background(Color(white: 0.98)) // minimalist white/off-white background
                .coordinateSpace(name: "SimulationContainer")
                .onAppear {
                    viewModel.updateBounds(geometry.size)
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewModel.updateBounds(newSize)
                }
            }
            .clipped()
        }
        .onAppear {
            viewModel.start()
            MotionManager.shared.start()
        }
        .onDisappear {
            viewModel.stop()
            MotionManager.shared.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.start()
                MotionManager.shared.start()
            case .inactive, .background:
                viewModel.stop()
                MotionManager.shared.stop()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showSummon) {
            SummonSheet(viewModel: viewModel)
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
    let isDirectFollow: Bool
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: ball.radius * 2, height: ball.radius * 2)
            // Add a subtle blue glow ring overlay and scale up slightly when direct dragging (hovering)
            .overlay(
                Circle()
                    .stroke(Color.blue.opacity(isDirectFollow ? 0.6 : 0.0), lineWidth: 3)
                    .scaleEffect(isDirectFollow ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isDirectFollow)
            )
            // Offset shadow opposite of gravity tilt. If direct follow is active,
            // increase shadow radius and offset to make the ball feel physically "lifted" and floating.
            .shadow(
                color: Color.black.opacity(isDirectFollow ? 0.35 : 0.18),
                radius: isDirectFollow ? 12.0 : 6.0,
                x: isDirectFollow ? 0 : -gravity.dx * 7.0,
                y: isDirectFollow ? 4.0 : -gravity.dy * 7.0
            )
            .position(ball.position)
    }
}

// MARK: - Popup Sheets

struct SettingsSheet: View {
    @ObservedObject var viewModel: SandboxViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Plane Settings")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Plane Friction")
                            Spacer()
                            Text(String(format: "%.2f", viewModel.planeFriction))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $viewModel.planeFriction, in: 0.0...1.0, step: 0.05)
                        Text("Higher values decelerate balls, making high-friction balls static / sticky.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Edge Bounciness")
                            Spacer()
                            Text(String(format: "%.2f", viewModel.edgeBounciness))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $viewModel.edgeBounciness, in: 0.0...1.0, step: 0.05)
                        Text("Coefficient of restitution for edge boundaries and ball-to-ball impacts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Gravity Settings")) {
                    Toggle("Enable Gravity", isOn: $viewModel.isGravityEnabled)
                    
                    if viewModel.isGravityEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                    Text("Gravity Strength")
                                    Spacer()
                                    Text("\(Int(viewModel.gravityMultiplier)) pt/s²")
                                        .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.gravityMultiplier, in: 100.0...2500.0, step: 50.0)
                        }
                        
                        Toggle("Axis-Locked Gravity", isOn: $viewModel.isAxisLocked)
                        Text("Snaps gravity to the nearest 3D axis plane. Laying the device flat on a table disables gravity, while tilting snaps it to vertical/horizontal axes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Sound Settings")) {
                    Toggle("Sound Effects", isOn: $viewModel.isSoundEnabled)
                    
                    if viewModel.isSoundEnabled {
                        Toggle("Rolling Rumble Sound", isOn: $viewModel.isRollingSoundEnabled)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Volume")
                                Spacer()
                                Text("\(Int(viewModel.masterVolume * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.masterVolume, in: 0.0...1.0, step: 0.05)
                        }
                    }
                }
                
                Section {
                    Button {
                        viewModel.loadChimePreset()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Load Chime Preset (Chord)")
                            Spacer()
                        }
                    }
                    
                    Button(role: .destructive) {
                        viewModel.deleteAllBalls()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete All Balls")
                            Spacer()
                        }
                    }
                    
                    Button {
                        viewModel.resetToDefaults()
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
    @ObservedObject var viewModel: SandboxViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var mass: Double = 2.0
    @State private var size: Double = 80.0 // Diameter
    @State private var rollingFriction: Double = 0.05
    @State private var bounciness: Double = 0.6
    
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
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bounciness")
                            Spacer()
                            Text(String(format: "%.2f", bounciness))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $bounciness, in: 0.0...1.0, step: 0.05)
                        Text("Individual restitution coefficient. Higher values bounce more elastically.")
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
                            
                            // Color mapping logic matched dynamically using viewModel's balls
                            let densities = viewModel.balls.map { $0.density } + [density]
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
                        viewModel.summonBall(
                            mass: CGFloat(mass),
                            size: CGFloat(size),
                            rollingFriction: CGFloat(rollingFriction),
                            bounciness: CGFloat(bounciness)
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
