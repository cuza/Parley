import AppIntents

/// Opens Parley's message search with these words, filters and results as ⌘F shows them.
struct SearchMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Messages"
    static let description = IntentDescription("Opens Parley's message search with these words.")
    static var parameterSummary: some ParameterSummary { Summary("Search Parley for \(\.$query)") }
    static let openAppWhenRun = true
    @Parameter(title: "Words") var query: String
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        store.searchRequest = SearchRequest(query: query)
        return .result()
    }
}
