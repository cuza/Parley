#if !canImport(os)
    import Testing
    @testable import ParleyDomain

    @Test func loggerKeepsPublicValuesAndHidesTheRest() {
        let name = "Ana"
        let status = 403
        let message: Logger.Message = "user \(name) got \(status, privacy: .public)"
        #expect(message.text == "user <private> got 403")
    }
#endif
