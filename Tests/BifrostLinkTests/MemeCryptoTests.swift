import Testing
@testable import BifrostLink

@Suite struct MemeCryptoTests {
    /// The game's own signature on the untouched save must verify, and re-signing it must give the
    /// exact same bytes the game wrote.
    @Test func ultraMoonSignature() throws {
        guard let original = Fixtures.load("3ds-001b5100.main") else { return }
        #expect(MemeCrypto.verify(original))
        let l = try #require(MemeCrypto.layout(saveSize: original.count))
        var resigned = original
        resigned.replaceSubrange(l.region..<(l.region + MemeCrypto.regionLength), with: [UInt8](repeating: 0, count: MemeCrypto.regionLength))
        MemeCrypto.sign(&resigned)
        #expect(resigned == original)
        // The broken file written earlier fails the check (that's what the game saw).
        if let broken = Fixtures.load("um-after.main") { #expect(!MemeCrypto.verify(broken)) }
    }
}
