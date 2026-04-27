import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "Системная"
        case .light:
            return "Светлая"
        case .dark:
            return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AccentOption: String, CaseIterable, Identifiable {
    case sky
    case coral
    case mint
    case amber
    case rose
    case indigo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sky:
            return "Sky"
        case .coral:
            return "Coral"
        case .mint:
            return "Mint"
        case .amber:
            return "Amber"
        case .rose:
            return "Rose"
        case .indigo:
            return "Indigo"
        }
    }

    var color: Color {
        switch self {
        case .sky:
            return Color(red: 0.18, green: 0.56, blue: 0.96)
        case .coral:
            return Color(red: 0.95, green: 0.42, blue: 0.34)
        case .mint:
            return Color(red: 0.08, green: 0.70, blue: 0.58)
        case .amber:
            return Color(red: 0.92, green: 0.60, blue: 0.16)
        case .rose:
            return Color(red: 0.88, green: 0.29, blue: 0.45)
        case .indigo:
            return Color(red: 0.35, green: 0.37, blue: 0.88)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .sky:
            return Color(red: 0.48, green: 0.79, blue: 1.0)
        case .coral:
            return Color(red: 1.0, green: 0.72, blue: 0.54)
        case .mint:
            return Color(red: 0.54, green: 0.91, blue: 0.82)
        case .amber:
            return Color(red: 1.0, green: 0.83, blue: 0.45)
        case .rose:
            return Color(red: 1.0, green: 0.66, blue: 0.74)
        case .indigo:
            return Color(red: 0.62, green: 0.68, blue: 1.0)
        }
    }
}
