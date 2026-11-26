import Foundation
import Testing
import TotalityCore
@testable import TotalityContacts

@Suite struct ContactCardTests {
    @Test func namesFallBackSensibly() {
        #expect(sam().name == "Sam Okafor")
        #expect(ContactCard(nickname: "Mom").name == "Mom")
        #expect(ContactCard(emails: [.init(label: "Email", value: "a@b.com")]).name == "a@b.com")
        #expect(ContactCard().name == "No name")
        var mom = ContactCard(givenName: "Linda", familyName: "Clemens", nickname: "Mom")
        #expect(mom.shownName == "Mom")
        #expect(mom.shortName == "Mom")
        mom.nickname = ""
        #expect(mom.shortName == "Linda")
    }

    @Test func sortsByFamilyName() {
        let cards = [sam(), priya(), ContactCard(nickname: "Dad")].sorted { $0.sortKey < $1.sortKey }
        #expect(cards.map(\.shownName) == ["Dad", "Sam Okafor", "Priya Patel"])
    }

    @Test func handlesAreNormalized() {
        #expect(ContactCard.normalizedHandle("@SamOkafor ") == "samokafor")
        #expect(ContactCard.normalizedHandle("no spaces") == nil)
        #expect(ContactCard.normalizedHandle("ab") == nil)
        #expect(sam().totalityAddress == "samokafor@usetotality.com")
    }

    @Test func tidyingDropsBlanksAndRepeats() {
        var card = sam()
        card.phones.append(.init(label: "Home", value: "  "))
        card.labels = ["Climbing", "climbing", " ", "Family"]
        card.birthday = .init(month: 2, day: 31)
        let tidy = card.tidied()
        #expect(tidy.phones.count == 1)
        #expect(tidy.labels == ["Climbing", "Family"])
        #expect(tidy.birthday == nil)
    }

    @Test func anOlderOrNewerCardStillOpens() throws {
        let minimal = #"{"id":"5A4D6E0B-7C5B-4A39-9B3E-2D0D7B1E9C11","givenName":"Wei","future":"ignored"}"#
        let card = try JSONDecoder().decode(ContactCard.self, from: Data(minimal.utf8))
        #expect(card.givenName == "Wei")
        #expect(card.phones.isEmpty && card.labels.isEmpty && !card.isFavourite)
    }

    @Test func knownPersonCarriesTheTotalityAddress() {
        let known = sam().known
        #expect(known.emails == ["sam.okafor@gmail.com", "samokafor@usetotality.com"])
        #expect(known.username == "samokafor")
    }
}

@Suite struct SearchTests {
    @Test func everyWordMatchesSomewhere() {
        #expect(ContactSearch.matches(sam(), terms: ["sam", "rope"]))
        #expect(ContactSearch.matches(sam(), terms: ["climbing"]))
        #expect(!ContactSearch.matches(sam(), terms: ["sam", "piano"]))
    }

    @Test func numbersMatchHoweverTheyreWritten() {
        #expect(ContactSearch.matches(sam(), terms: ["5550142"]))
        #expect(ContactSearch.matches(sam(), terms: ["555-0142"]))
        #expect(!ContactSearch.matches(sam(), terms: ["12"]))
    }

    @Test func summaryLinesFollowTheCanvas() {
        #expect(ContactSearch.summary(sam(), upcoming: nil, calendar: utc) == ("@samokafor on Totality", true))
        let mom = momOnPhone.card(at: friday)
        #expect(ContactSearch.summary(mom, upcoming: nil, calendar: utc).text == "Mobile · 2 email addresses")
        let next = Birthdays.upcoming([priya()], from: friday, in: utc).first
        #expect(ContactSearch.summary(priya(), upcoming: next, calendar: utc).text == "Birthday Sunday")
    }
}

@Suite struct BirthdayTests {
    @Test func nextBirthdayAndAge() throws {
        let next = try #require(Birthdays.upcoming([priya()], from: friday, in: utc).first)
        #expect(next.daysAway == 4)
        #expect(next.turning == 27)
        #expect(Birthdays.headline(next, in: utc) == "Priya Patel's birthday is Sunday")
        #expect(Birthdays.detail(next, in: utc) == "22 November · turning 27")
    }

    @Test func leapDayFallsOnThe28th() throws {
        let card = ContactCard(givenName: "Leap", birthday: .init(month: 2, day: 29))
        let date = try #require(Birthdays.next(card.birthday!, from: friday, in: utc))
        #expect(utc.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2027, month: 2, day: 28))
    }

    @Test func calendarGetsAllDayItemsWithTitlesOnly() {
        let start = utc.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let end = utc.date(byAdding: .day, value: 7, to: start)!
        let items = Birthdays.agenda([priya(), sam()], from: start, to: end, in: utc)
        #expect(items.count == 1)
        #expect(items[0].title == "Priya Patel's birthday")
        #expect(items[0].isAllDay && items[0].module == .contacts)
        #expect(items[0].detail == "Turning 27")
        var gone = priya()
        gone.deletedAt = friday
        #expect(Birthdays.agenda([gone], from: start, to: end, in: utc).isEmpty)
    }
}

@Suite struct MergeAndVCardTests {
    @Test func mergeKeepsEverythingOnce() {
        var other = ContactCard(
            givenName: "Samuel", phones: [.init(label: "Mobile", value: "801-555-0142"), .init(label: "Work", value: "801 555 0100")],
            emails: [.init(label: "Email", value: "SAM.OKAFOR@gmail.com")], notes: "Lent me a cam.", labels: ["BYU"]
        )
        other.isFavourite = true
        let merged = ContactMerge.merge(keep: sam(), other: other, at: friday)
        #expect(merged.givenName == "Sam")
        #expect(merged.phones.count == 2)
        #expect(merged.emails.count == 1)
        #expect(merged.labels == ["Climbing", "BYU"])
        #expect(merged.notes == "Climbing partner. Has the 70 m rope.\n\nLent me a cam.")
        #expect(merged.isFavourite)
    }

    @Test func vCardLeavesOutPrivateFieldsUnlessAsked() {
        let text = VCard.text(sam())
        #expect(text.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        #expect(text.contains("N:Okafor;Sam;;;"))
        #expect(text.contains("TEL;TYPE=CELL:(801) 555-0142"))
        #expect(text.contains("EMAIL;TYPE=INTERNET:samokafor@usetotality.com"))
        #expect(text.contains("BDAY:--03-14"))
        #expect(!text.contains("NOTE") && !text.contains("CATEGORIES"))
        let full = VCard.text(sam(), options: .init(notes: true, labels: true))
        #expect(full.contains("NOTE:Climbing partner. Has the 70 m rope."))
        #expect(full.contains("CATEGORIES:Climbing"))
    }

    @Test func vCardEscapesAndFolds() {
        let card = ContactCard(givenName: "A;B", company: "X, Y", notes: String(repeating: "é", count: 60))
        let text = VCard.text(card, options: .init(notes: true))
        #expect(text.contains("FN:A\\;B"))
        #expect(text.contains("ORG:X\\, Y"))
        #expect(text.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        #expect(VCard.fileName(ContactCard(givenName: "a/b")) == "a-b.vcf")
    }
}

@Suite struct VaultTests {
    @Test func cardsAreSealedAndNamedByIDOnly() async throws {
        let store = MemoryBlobStore()
        let vault = ContactVault(store: store, rootKey: try ContentRootKey.generate())
        let card = sam()
        try await vault.save(card)
        let names = Array(store.all.keys)
        #expect(names == ["\(card.id.uuidString.lowercased()).contact"])
        let sealed = try #require(store.all.values.first)
        #expect(sealed.range(of: Data("Okafor".utf8)) == nil)
        #expect(sealed.range(of: Data("samokafor".utf8)) == nil)
        #expect(try await vault.card(card.id) == card)
    }

    @Test func aCardThatWontOpenIsCountedAndKept() async throws {
        let store = MemoryBlobStore()
        let vault = ContactVault(store: store, rootKey: try ContentRootKey.generate())
        try await vault.save(sam())
        try store.write(Data("garbage".utf8), as: "\(UUID().uuidString.lowercased()).contact")
        let listing = try await vault.everything()
        #expect(listing.cards.count == 1)
        #expect(listing.unreadable == 1)
        #expect(store.all.count == 2)
    }

    @Test func syncConflictKeepsTheNewer() async throws {
        let key = try ContentRootKey.generate()
        let a = ContactVault(store: MemoryBlobStore(), rootKey: key), b = ContactVault(store: MemoryBlobStore(), rootKey: key)
        var card = sam()
        try await a.save(card)
        card.notes = "Newer"
        card.updatedAt = friday.addingTimeInterval(60)
        try await b.save(card)
        let local = try #require(try await a.sealedObject(card.id)), remote = try #require(try await b.sealedObject(card.id))
        #expect(try await a.resolveConflict(local: local, remote: remote) == .keepRemote)
        #expect(try await b.resolveConflict(local: remote, remote: local) == .keepLocal)
    }

    @Test func deleteForGoodLeavesARecord() async throws {
        let store = MemoryBlobStore()
        let vault = ContactVault(store: store, rootKey: try ContentRootKey.generate())
        let card = sam()
        try await vault.save(card)
        try await vault.delete(card.id)
        #expect(try await vault.sealedObjectIDs().isEmpty)
        #expect(try await vault.deletedObjectIDs() == [card.id])
    }
}

@MainActor
@Suite struct ModelTests {
    @Test func recentlyDeletedRestoresAndExpires() async throws {
        let (model, vault) = try makeModel()
        await model.load()
        let saved = try #require(await model.save(sam(), over: nil))
        await model.delete(saved)
        #expect(model.live.isEmpty)
        #expect(model.deleted.count == 1)
        #expect(model.daysLeft(model.deleted[0]) == 30)
        await model.restore(model.deleted[0])
        #expect(model.live.count == 1)

        // A card deleted 31 days ago goes for good when Contacts next opens.
        var old = priya()
        old.deletedAt = friday.addingTimeInterval(-31 * 86_400)
        try await vault.save(old)
        await model.load()
        #expect(model.card(old.id) == nil)
        #expect(try await vault.deletedObjectIDs().contains(old.id))
    }

    @Test func mergeSendsTheOtherToRecentlyDeleted() async throws {
        let (model, _) = try makeModel()
        await model.load()
        let a = try #require(await model.save(sam(), over: nil))
        let b = try #require(await model.save(ContactCard(givenName: "Samuel", phones: [.init(label: "Work", value: "801 555 0100")]), over: nil))
        let merged = try #require(await model.merge(keep: a, other: b))
        #expect(merged.phones.count == 2)
        #expect(model.live.map(\.id) == [a.id])
        #expect(model.deleted.map(\.id) == [b.id])
    }

    @Test func importCopiesOnlyWhatsChosenAndNotNotes() async throws {
        let device = FakeDevice([momOnPhone, elenaOnPhone], access: .notAsked, grants: .limited)
        let (model, _) = try makeModel(device: device)
        await model.load()
        #expect(model.deviceAccess == .notAsked, "nothing is asked on opening")
        #expect(await model.askForDeviceAccess() == .limited)
        let waiting = await model.notYetCopied()
        #expect(waiting.count == 2)
        await model.copy([momOnPhone])
        #expect(model.live.map(\.shownName) == ["Mom"])
        #expect(model.live[0].notes.isEmpty)
        #expect(model.live[0].origin?.deviceID == "device-mom")
        #expect(await model.notYetCopied().map(\.id) == ["device-elena"])
    }

    @Test func updateFromIPhoneShowsChangesFirstAndKeepsTotalitysOwn() async throws {
        let device = FakeDevice([momOnPhone])
        let (model, _) = try makeModel(device: device)
        await model.load()
        await model.copy([momOnPhone])
        var card = model.live[0]
        card.notes = "Call on Sundays"
        card.labels = ["Family"]
        await model.save(card, over: model.live[0])
        #expect(await model.pendingUpdates().isEmpty)

        var changed = momOnPhone
        changed.phones = [.init(label: "Mobile", value: "(801) 555-0187")]
        device.change(changed)
        let updates = await model.pendingUpdates()
        #expect(updates.count == 1)
        #expect(updates[0].changes.contains("Phone + (801) 555-0187"))
        #expect(model.live[0].phoneNumbers == ["(801) 555-0110"], "nothing saved before Save")
        await model.apply(updates)
        #expect(model.live[0].phoneNumbers == ["(801) 555-0187"])
        #expect(model.live[0].notes == "Call on Sundays")
        #expect(model.live[0].labels == ["Family"])
        #expect(await model.pendingUpdates().isEmpty)
    }

    @Test func twoWaySyncWritesBackButNeverNotes() async throws {
        let device = FakeDevice([momOnPhone])
        let (model, _) = try makeModel(device: device)
        await model.load()
        await model.copy([momOnPhone])
        var card = model.live[0]
        card.company = "Retired"
        await model.save(card, over: model.live[0])
        #expect(device.writes.isEmpty, "off by default")

        model.twoWaySync = true
        card = model.live[0]
        card.notes = "Private note"
        card.company = "Volunteer"
        await model.save(card, over: model.live[0])
        let written = try #require(device.writes.last)
        #expect(written.company == "Volunteer")
        #expect(await model.pendingUpdates().isEmpty, "what was written isn't seen as a change from the iPhone")
    }

    @Test func groupMailUsesEachPersonsFirstAddress() async throws {
        let (model, _) = try makeModel()
        await model.load()
        await model.save(sam(), over: nil)
        var jordan = ContactCard(givenName: "Jordan", familyName: "Bennett", emails: [.init(label: "Email", value: "jordan.bennett@gmail.com")])
        jordan.labels = ["Climbing"]
        await model.save(jordan, over: nil)
        var rosa = ContactCard(givenName: "Rosa", familyName: "Mendes")
        rosa.labels = ["Climbing"]
        await model.save(rosa, over: nil)
        model.label = "Climbing"
        #expect(model.shown.count == 3)
        #expect(model.groupAddresses == ["jordan.bennett@gmail.com", "sam.okafor@gmail.com"])
    }

    @Test func directoryAnswersMailAndMessages() async throws {
        let (model, _) = try makeModel()
        await model.load()
        var mom = momOnPhone.card(at: friday)
        mom.username = "lindac"
        await model.save(mom, over: nil)
        #expect(model.directory.person(email: "LINDA@example.com")?.shownName == "Mom")
        #expect(model.directory.person(username: "@lindac")?.name == "Linda Clemens")
        #expect(model.directory.people(matching: "mo", limit: 5).map(\.shownName) == ["Mom"])
        #expect(model.directory.people(matching: "linda@w", limit: 5).count == 1)
        await model.delete(model.live[0])
        #expect(model.directory.person(email: "linda@example.com") == nil, "Recently Deleted isn't known")
        await model.stopForKeyChange()
        #expect(model.directory.people(matching: "m", limit: 5).isEmpty)
    }
}

@Suite struct ModuleTests {
    @Test func addToContactsLinksOnceAndSearchFindsIt() async throws {
        let vault = ContactVault(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let module = ContactsModule(vault: vault, directory: ContactsDirectory(), calendar: { utc }, now: { friday })
        let ref = try await module.addContact(username: "@SamOkafor", displayName: "Sam Okafor")
        let again = try await module.addContact(username: "samokafor", displayName: "Someone else")
        #expect(ref.id == again.id)
        #expect(ref.kind == .contact && ref.preview.title == "Sam Okafor")
        #expect(await module.hasContact(username: "samokafor"))
        await #expect(throws: ContactsModuleError.invalidUsername) { try await module.addContact(username: "a b", displayName: nil) }
        let hits = try await module.search("okafor")
        #expect(hits.map(\.title) == ["Sam Okafor"])
        #expect(try await module.current(ref)?.id == ref.id)
    }

    @Test func registryFindsPeopleAndTheMaker() throws {
        let directory = ContactsDirectory()
        directory.update([sam()])
        let registry = try ModuleRegistry(handlers: [ContactsModule(vault: nil, directory: directory)])
        #expect(registry.people?.person(username: "samokafor")?.name == "Sam Okafor")
        #expect(registry.contactMaker != nil)
        #expect(registry.receiver(for: .social) == nil, "Contacts never takes over Save to Reader")
    }
}
