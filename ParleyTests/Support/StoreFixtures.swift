@testable import Parley
@testable import ParleyDomain

/// A store started on `fake`'s demo workspace, landing on `shortcut` when one is given.
@MainActor func started(_ fake: FakeBackend = FakeBackend(), shortcut: Shortcut? = nil) async -> (
    ChatStore, FakeBackend
) {
    let store = ChatStore(backend: fake)
    store.navigation.shortcut = shortcut
    await store.start()
    return (store, fake)
}
