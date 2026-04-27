//
//  WeatherBoxApp.swift
//  WeatherBox
//
//  Created by FergeS on 28.03.2026.
//

import SwiftUI

@main
struct WeatherBoxApp: App {
    private let accentOption = AccentOption.sky

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accentOption.color)
        }
    }
}
