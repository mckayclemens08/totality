import Foundation
import Testing
import TotalityCore
@testable import TotalityContacts

/// Contacts' case of the two-user test (definition of done, issue 205 step 8): user B can't read or replace
/// user A's cards, and a link to B holds only B's handle, never anything of B's. The server side of the same
/// case is in backend-tests/two-user.test.js.
@Suite struct ContactsTwoUserTests {
    @Test func anotherPersonCantReadOrReplaceACard() async throws {
        let a = ContactVault(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let b = ContactVault(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let card = sam()
        try await a.save(card)
        let sealed = try #require(try await a.sealedObject(card.id))

        // B's device is handed A's card, as a server could: it never opens it.
        await #expect(throws: (any Error).self) { try await b.store(sealed, ifLocalHash: nil) }
        #expect(try await b.everything().cards.isEmpty)

        // B's own card, sent to A's device under A's ID, is refused, and A's card stays.
        let theirs = priya()
        try await b.save(theirs)
        let forged = try #require(try await b.sealedObject(theirs.id))
        let swapped = SealedObject(id: card.id, kind: .contact, meta: forged.meta, body: nil)
        await #expect(throws: (any Error).self) { try await a.store(swapped, ifLocalHash: sealed.hash) }
        #expect(try await a.card(card.id) == card)

        // Nor can a card pass for another kind.
        let relabelled = SealedObject(id: card.id, kind: .task, meta: sealed.meta, body: nil)
        await #expect(throws: (any Error).self) { try await a.store(relabelled, ifLocalHash: sealed.hash) }
    }

    @Test func aLinkHoldsOnlyTheHandle() async throws {
        // A links a card to B's handle. The card holds the handle and A's own words, nothing fetched from B.
        let vault = ContactVault(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let module = ContactsModule(vault: vault, directory: ContactsDirectory())
        let ref = try await module.addContact(username: "weichen", displayName: "Wei Chen")
        let card = try await vault.card(ref.id)
        #expect(card.username == "weichen")
        #expect(card.photo == nil && card.phones.isEmpty && card.emails.isEmpty)
        #expect(ref.keyRef == .crk(objectID: ref.id), "sealed under A's own key")
    }
}
