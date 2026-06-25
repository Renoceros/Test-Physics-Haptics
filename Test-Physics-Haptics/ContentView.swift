//
//  ContentView.swift
//  Test-Physics-Haptics
//
//  Created by Moreno Kristovan on 25/06/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

/// I'm trying to make an app that uses physics and haptics, core motion as well, the app will be a simple app, with a 2d physics circles, one large one small, white bg, grey circles, when the circles act as if they're 3d spheres on a plane the phone is a plane, if it's facing up the balls fall down, each thud/contact with a bounding wall it's a sharp buzz the sharpness n duration is depending on the simulated forces, the balls have the diffrent densities, maked by the darker the color is the denser they are, we can drag it arround but it's not gonna be locked to the touch on the screen the touch will like "rubberband" depending on the mass of the ball and to better show the heft there's vibration when you move it with your finger or move them with the phone, there's the matter of bouncyness but uh.. idk how to do that develop that part, the app is just one screen with a setting button leading and + button trailing, delete all will delete all, + button would show a popup you can change the properties of the balls, we can change rolling friction coeficient, mass, size and a button "summon". color is just a scale from grayscale 0.8-0 normalized with the density via mass/size, some balls are sticky and stick to the plane if it has high rolling friction coef, etc3. have the physics modulate the haptics, but logic for the triggers, idk how you would intend to make the edges redirect the force vector, can be simple mirroring approach angle but multiply the force with a coef, which can be changed in settings popup for the button, the settings popup can change the coef friction of the plane, "bounciness" of the edges, and a button to delete all the balls. Your task is to develop this idea but keep it VERY simple, and remember to use GIT
