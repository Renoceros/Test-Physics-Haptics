//
//  Sphere.swift
//  Test-Physics-Haptics
//
//  Created by Syauqi Auliya M on 30/06/26.
//

//Update
import SwiftUI
import UIKit

// MARK: - CoreGraphics Sphere UIView

class CGSphereUIView: UIView {
    var sphereColor: UIColor = .blue {
        didSet {
            setNeedsDisplay()
        }
    }
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        let size = rect.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        
        // Define bounding rect of the sphere
        let sphereRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        
        // Save graphics state
        context.saveGState()
        
        // Clip context to the circle path
        context.addEllipse(in: sphereRect)
        context.clip()
        
        // Shift gradient start point up and left to simulate a light source
        let lightSource = CGPoint(
            x: center.x - (radius * 0.35),
            y: center.y - (radius * 0.35)
        )
        
        // Extract RGBA from sphereColor to calculate base/mid/shadow gradients dynamically
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        sphereColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Create midtone (slightly darker) and shadow (much darker/saturated) colors
        let midColor = UIColor(
            red: max(red - 0.2, 0.0),
            green: max(green - 0.2, 0.0),
            blue: max(blue - 0.2, 0.0),
            alpha: alpha
        )
        
        let shadowColor = UIColor(
            red: max(red - 0.65, 0.0),
            green: max(green - 0.65, 0.0),
            blue: max(blue - 0.65, 0.0),
            alpha: alpha
        )
        
        // Colors array: Specular highlight (bright white) -> Base Color -> Midtone -> Shadow
        let colors = [
            UIColor.white.cgColor,
            sphereColor.cgColor,
            midColor.cgColor,
            shadowColor.cgColor
        ] as CFArray
        
        // Locations corresponding to color stops
        let locations: [CGFloat] = [0.0, 0.3, 0.75, 1.0]
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            context.restoreGState()
            return
        }
        
        // Draw the radial gradient (concentric to the light source)
        context.drawRadialGradient(
            gradient,
            startCenter: lightSource,
            startRadius: 0,
            endCenter: lightSource,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
        
        // Restore graphics state
        context.restoreGState()
    }
}

// MARK: - SwiftUI Representable Wrapper

struct CoreGraphicsSphereView: UIViewRepresentable {
    let color: UIColor
    
    func makeUIView(context: Context) -> CGSphereUIView {
        let view = CGSphereUIView()
        view.backgroundColor = .clear // Transparent background
        view.sphereColor = color
        return view
    }
    
    func updateUIView(_ uiView: CGSphereUIView, context: Context) {
        uiView.sphereColor = color
    }
}

// MARK: - Carousel Sphere Item View

struct CarouselSphereItem: View {
    let color: UIColor
    let baseScale: CGFloat
    let opacity: Double
    let z: CGFloat
    
    var body: some View {
        CoreGraphicsSphereView(color: color)
            .frame(width: 220, height: 220)
            .shadow(
                color: Color.black.opacity(0.12 * ((z + 1.0) / 2.0)),
                radius: 10 * baseScale,
                x: 0,
                y: 8 * baseScale
            )
            .scaleEffect(baseScale)
            .opacity(opacity)
    }
}

// MARK: - Main SphereView (Circular Carousel)

struct SphereView: View {
    let colors: [UIColor] = [
        .systemRed,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .systemIndigo,
    ]
    
    let colorNames = [
        "Red", "Yellow", "Green", "Blue", "Indigo"
    ]
    
    @State private var rotationAngle: CGFloat = 0.0
    @State private var dragTranslation: CGFloat = 0.0
    
    private func getCurrentAngle() -> CGFloat {
        let dragAngle = (dragTranslation / 300.0) * CGFloat.pi
        return rotationAngle + dragAngle
    }
    
    private func getSelectedIndex() -> Int {
        let currentAngle = getCurrentAngle()
        let spacing = (2.0 * CGFloat.pi) / CGFloat(colors.count)
        let rawIndex = Int(round(-currentAngle / spacing)) % colors.count
        return rawIndex >= 0 ? rawIndex : rawIndex + colors.count
    }
    
    var body: some View {
        ZStack {
            // Elegant off-white light background
            Color(white: 0.97)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Text("CoreGraphics Carousel")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(Color(white: 0.2))
                    .padding(.top, 40)
                
                Spacer()
                
                // The Merry-Go-Round Container
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let center = CGPoint(x: width / 2, y: height / 2)
                    
                    // Radii of the ellipse path
                    let rx = /*min(width * 0.47, 190.0)*/ 240.0
                    let ry = 50.0 // More depth tilt for perspective spacing
                    
                    let currentAngle = getCurrentAngle()
                    
                    ZStack {
                        // Circular guide path on the floor to make it feel grounded
                        Ellipse()
                            .stroke(Color.gray.opacity(0.08), lineWidth: 2)
                            .frame(width: rx * 2, height: ry * 2)
                            .position(center)
                            .offset(y: 80) // offset down slightly to serve as a floor guide
                        
                        ForEach(0..<colors.count, id: \.self) { index in
                            let spacing = (2.0 * CGFloat.pi) / CGFloat(colors.count)
                            let theta = currentAngle + (CGFloat(index) * spacing)
                            
                            let x = center.x + rx * sin(theta)
                            let y = center.y + ry * cos(theta)
                            
                            let z = cos(theta)
                            let proximity = (z + 1.0) / 2.0
                            let pop = pow(proximity, 6)
                            let baseScale = (0.25 + 0.75 * proximity) * (1.0 + 0.3 * pop)
                            let opacity = 0.0 + 1.0 * proximity
                            
                            CarouselSphereItem(
                                color: colors[index],
                                baseScale: baseScale,
                                opacity: opacity,
                                z: z
                            )
                            .position(x: x, y: y)
                            .zIndex(Double(z))
                        }
                    }
                }
                .frame(height: 320)
                .contentShape(Rectangle()) // makes the entire area gesture-responsive
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let translation = value.translation.width
                            let spacing = (2.0 * CGFloat.pi) / CGFloat(colors.count)
                            let angleChange = (translation / 300.0) * CGFloat.pi
                            let finalAngle = rotationAngle + angleChange
                            
                            // Snap to target angle
                            let targetAngle = round(-finalAngle / spacing) * -spacing
                            
                            // Instantly shift state variables to the final drag state so no visual snapping backwards happens
                            rotationAngle = finalAngle
                            dragTranslation = 0.0
                            
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82, blendDuration: 0)) {
                                rotationAngle = targetAngle
                            }
                        }
                )
                
                Spacer()
                
                // Info display showing which sphere is currently snapped to the front
                let selectedIndex = getSelectedIndex()
                
                VStack(spacing: 8) {
                    Text("\(colorNames[selectedIndex]) Sphere")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(Color(colors[selectedIndex]))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(
                            Capsule()
                                .fill(Color(colors[selectedIndex]).opacity(0.12))
                        )
                        .animation(.easeInOut(duration: 0.25), value: selectedIndex)
                    
                    Text("Swipe horizontally to spin the carousel")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 60)
            }
        }
    }
}

#Preview {
    SphereView()
}
