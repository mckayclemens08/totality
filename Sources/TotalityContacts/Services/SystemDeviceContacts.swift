#if canImport(Contacts)
import Contacts
import Foundation

/// The iPhone's own Contacts, through Apple's Contacts framework. Asked only when the person taps Choose from
/// iPhone Contacts (issue 205, section 4). Notes are never in the keys asked for.
public final class SystemDeviceContacts: DeviceContacts, @unchecked Sendable {
    private let store = CNContactStore()

    public init() {}

    static var keys: [CNKeyDescriptor] {
        [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
        CNContactThumbnailImageDataKey,
        ] as [CNKeyDescriptor]
    }

    public var access: DeviceAccess {
        Self.access(CNContactStore.authorizationStatus(for: .contacts))
    }

    static func access(_ status: CNAuthorizationStatus) -> DeviceAccess {
        #if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return .limited }
        #endif
        switch status {
        case .authorized: return .full
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> DeviceAccess {
        _ = try? await store.requestAccess(for: .contacts)
        return access
    }

    public func all() async throws -> [DeviceContact] {
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            var found: [DeviceContact] = []
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            request.sortOrder = .familyName
            try store.enumerateContacts(with: request) { contact, _ in found.append(Self.copy(contact)) }
            return found
        }.value
    }

    public func contacts(_ ids: [String]) async throws -> [DeviceContact] {
        guard !ids.isEmpty else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let predicate = CNContact.predicateForContacts(withIdentifiers: ids)
            return try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys).map(Self.copy)
        }.value
    }

    public func update(_ contact: DeviceContact) async throws {
        try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            guard let found = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [contact.id]), keysToFetch: Self.keys
            ).first, let mutable = found.mutableCopy() as? CNMutableContact else { return }
            mutable.givenName = contact.givenName
            mutable.familyName = contact.familyName
            mutable.nickname = contact.nickname
            mutable.organizationName = contact.company
            mutable.phoneNumbers = contact.phones.map { CNLabeledValue(label: Self.label($0.label), value: CNPhoneNumber(stringValue: $0.value)) }
            mutable.emailAddresses = contact.emails.map { CNLabeledValue(label: Self.label($0.label), value: $0.value as NSString) }
            mutable.postalAddresses = contact.addresses.map { place in
                let address = CNMutablePostalAddress()
                address.street = place.street
                address.city = place.city
                address.state = place.region
                address.postalCode = place.postcode
                address.country = place.country
                return CNLabeledValue(label: Self.label(place.label), value: address.copy() as! CNPostalAddress)
            }
            mutable.birthday = contact.birthday.map { DateComponents(year: $0.year, month: $0.month, day: $0.day) }
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }.value
    }

    static func copy(_ contact: CNContact) -> DeviceContact {
        DeviceContact(
            id: contact.identifier, givenName: contact.givenName, familyName: contact.familyName, nickname: contact.nickname,
            company: contact.organizationName,
            phones: contact.phoneNumbers.map { .init(label: name(of: $0.label, fallback: "Phone"), value: $0.value.stringValue) },
            emails: contact.emailAddresses.map { .init(label: name(of: $0.label, fallback: "Email"), value: $0.value as String) },
            addresses: contact.postalAddresses.map { labeled in
                let place = labeled.value
                return .init(
                    label: name(of: labeled.label, fallback: "Address"), street: place.street, city: place.city,
                    region: place.state, postcode: place.postalCode, country: place.country
                )
            },
            birthday: contact.birthday.flatMap { parts in
                guard let month = parts.month, let day = parts.day else { return nil }
                return .init(month: month, day: day, year: parts.year.flatMap { $0 == NSDateComponentUndefined ? nil : $0 })
            },
            photo: contact.thumbnailImageData
        )
    }

    /// "_$!<Mobile>!$_" as the person sees it, such as "Mobile".
    static func name(of label: String?, fallback: String) -> String {
        guard let label, !label.isEmpty else { return fallback }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }

    static func label(_ shown: String) -> String {
        switch shown.lowercased() {
        case "mobile": CNLabelPhoneNumberMobile
        case "iphone": CNLabelPhoneNumberiPhone
        case "main": CNLabelPhoneNumberMain
        case "home": CNLabelHome
        case "work": CNLabelWork
        case "school": CNLabelSchool
        case "other": CNLabelOther
        default: shown
        }
    }
}
#endif
