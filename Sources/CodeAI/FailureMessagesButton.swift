import SwiftUI

public struct FailureMessagesButton: View {
    var messages: [String]?

    public init(messages: [String]? = nil) {
        self.messages = messages
    }
    
    public var body: some View {
        Group {
            if let messages = messages, !messages.isEmpty {
                Menu {
                    ForEach(messages, id: \.self) { message in
                        Text(message)
                    }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .menuIndicator(.hidden)
            }
        }
    }
}
