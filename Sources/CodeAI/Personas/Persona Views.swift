import SwiftUI
import RealmSwift

public struct PersonaStyleIcon: View {
    var size: CGFloat
    var iconSymbol: String? = nil
    var sfSymbol: String? = nil
    let tint: Color
    var isFilled = true
    
    public var body: some View {
        ZStack {
            if let iconSymbol = iconSymbol {
                Color.clear
                    .overlay {
                        // Overlay prevents list line separator alignment with text.
                        Text(iconSymbol)
                            .font(.system(size: size * 0.6).weight(.semibold))
                    }
            } else {
                if let sfSymbol = sfSymbol {
                    Image(systemName: sfSymbol)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(1)
                }
            }
        }
        .font(.body.weight(.semibold))
        .padding(4)
        .foregroundColor(isFilled ? .white : .primary)
        .frame(width: size, height: size)
        .background {
            if isFilled {
                Circle()
                    .fill(tint.opacity(0.6))
            } else {
                Circle()
                    .stroke(tint.opacity(0.6), lineWidth: 4)
            }
        }
        .clipShape(Circle())
    }
    
    public init(size: CGFloat = 21, iconSymbol: String? = nil, sfSymbol: String? = nil, tint: Color, isFilled: Bool = true) {
        self.size = size
        self.iconSymbol = iconSymbol
        self.sfSymbol = sfSymbol
        self.tint = tint
        self.isFilled = isFilled
    }
}

public struct PersonaStyleButton: View {
    var iconSymbol: String? = nil
    var sfSymbol: String? = nil
    let tint: Color
    var isFilled = true
    let action: (() -> Void)
    
    public var body: some View {
        Button {
            action()
        } label: {
            PersonaStyleIcon(iconSymbol: iconSymbol, sfSymbol: sfSymbol, tint: tint, isFilled: isFilled)
        }
        .buttonStyle(.plain)
    }
    
    public init(iconSymbol: String? = nil, sfSymbol: String? = nil, tint: Color, isFilled: Bool = true, action: @escaping () -> Void) {
        self.iconSymbol = iconSymbol
        self.sfSymbol = sfSymbol
        self.tint = tint
        self.isFilled = isFilled
        self.action = action
    }
}

public protocol PersonaIconProtocol {
    var persona: Persona { get }
}

public extension PersonaIconProtocol {
    var symbol: String {
        if let iconSymbol = persona.iconSymbol {
            return iconSymbol
        }
        if let firstChar = persona.name.first {
            return String(firstChar)
        }
        return "?"
    }
    
    var personaTint: Color {
        switch persona.tint {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .gray: return .gray
        }
    }
}

public struct PersonaIcon: View, PersonaIconProtocol {
    @ObservedRealmObject public var persona: Persona
    var size: CGFloat
    
    public var body: some View {
        PersonaStyleIcon(size: size, iconSymbol: symbol, tint: personaTint)
    }
    
    public init(persona: Persona, size: CGFloat = 21) {
        self.persona = persona
        self.size = size
    }
}

public struct PersonaButton: View, PersonaIconProtocol {
    @ObservedRealmObject public var persona: Persona
    let action: (() -> Void)
    
    public var body: some View {
        PersonaStyleButton(iconSymbol: symbol, tint: personaTint, action: action)
    }
    
    public init(persona: Persona, action: @escaping () -> Void) {
        self.persona = persona
        self.action = action
    }
}
