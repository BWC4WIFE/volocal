import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("ttsEnabled") var ttsEnabled: Bool = false           // OFF by default
    @AppStorage("multiLanguageMode") var multiLanguageMode: Bool = false  // Thai-only by default
    // Future: @AppStorage("englishToThaiMode") var englishToThaiMode: Bool = false
}
