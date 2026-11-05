/// Where every account's mail address lives. A username can't change, so neither can its address.
public enum MailDomain {
    public static let name = "usetotality.com"

    public static func address(for username: String) -> String {
        "\(username.lowercased())@\(name)"
    }
}
