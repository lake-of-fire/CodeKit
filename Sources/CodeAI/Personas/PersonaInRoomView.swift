import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import CodeCore

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
                    .tint(.red)
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

public extension View {
    func personaInRoomPopover(persona: Persona, room: Room, isPresented: Binding<Bool>, arrowEdge: Edge) -> some View {
        self.modifier(PersonaInRoomPopoverModifier(persona: persona, room: room, isPresented: isPresented, arrowEdge: arrowEdge))
    }
}

struct PersonaInRoomPopoverModifier: ViewModifier {
    let persona: Persona
    let room: Room
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    
    @ScaledMetric(relativeTo: .body) private var idealWidth = 370
    @ScaledMetric(relativeTo: .body) private var idealHeight = 420
    
    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
#if os(iOS)
                NavigationStack {
                    PersonaInRoomView(persona: persona, room: room) {
                        isPresented = false
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button("Done") {
                                isPresented = false
                            }
                            .bold()
                        }
                    }
                    .navigationTitle(persona.name)
                    .navigationBarTitleDisplayMode(.inline)
                }
                .frame(idealWidth: idealWidth, idealHeight: idealHeight)
#else
                PersonaInRoomView(persona: persona, room: room) {
                    isPresented = false
                }
                .frame(idealWidth: idealWidth, idealHeight: idealHeight)
#endif
            }
    }
}
