import Foundation

struct ConversationMessage: Identifiable {
    let id = UUID()
    var role: Role
    var text: String
    var originalText: String?
    let timestamp = Date()

    enum Role {
        case user
        case assistant
    }
}
