import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps

public struct PersonaInRoomView: View {
    let persona: Persona
    let room: Room
    let onRemoved: () -> Void
    
    @ScaledMetric(relativeTo: .body) private var idealWidth = 370
    @ScaledMetric(relativeTo: .body) private var idealHeight = 390
    
    public var body: some View {
        PersonaDetailsView(persona: persona)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        safeWrite(room) { realm, room in
                            guard let matchPersona = realm?.object(ofType: Persona.self, forPrimaryKey: persona.id) else { return }
                            room.participants.remove(matchPersona)
                        }
                        onRemoved()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Remove from Room")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(10)
                }
                .background(.ultraThinMaterial)
            }
            .frame(idealWidth: idealWidth, idealHeight: idealHeight)
    }
    
    public init(persona: Persona, room: Room, onRemoved: @escaping () -> Void) {
        self.persona = persona
        self.room = room
        self.onRemoved = onRemoved
    }
}
