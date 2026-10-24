import Foundation
import ParleyDomain

extension ChatStore {
    /// Search results for `query` and the filters; ⌘F's conversation is a "said in" filter.
    func search(_ query: String, filters: SearchFilters = SearchFilters()) async {
        searchGeneration += 1
        let generation = searchGeneration
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty || !filters.isEmpty else {
            searchResults = []
            return
        }  // chips alone search too
        do {
            let page = try await backend.searchMessages(matching: query, filters: filters, cursor: nil)
            if generation == searchGeneration { searchResults = page.messages }
        } catch { if generation == searchGeneration { report(error) } }
    }
}
