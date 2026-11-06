import Contacts
import ContactsUI
import UIKit

/// "Use My Contact Photo": iOS gives apps no access to the account picture in Settings, but the
/// user's own contact card normally carries the same photo. The system contact picker
/// needs no Contacts permission; only the chosen card's picture is used.
@MainActor
final class ContactPhotoPicker: NSObject, CNContactPickerDelegate {
    private var completion: ((UIImage?) -> Void)?
    private var retainSelf: ContactPhotoPicker?

    static func present(completion: @escaping (UIImage?) -> Void) {
        let picker = ContactPhotoPicker()
        picker.completion = completion
        picker.retainSelf = picker
        let controller = CNContactPickerViewController()
        controller.delegate = picker
        controller.predicateForEnablingContact = NSPredicate(format: "imageDataAvailable == true")
        topViewController()?.present(controller, animated: true)
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let data = contact.isKeyAvailable(CNContactImageDataKey) ? contact.imageData : nil
        MainActor.assumeIsolated { finish(data.flatMap(UIImage.init(data:))) }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func finish(_ image: UIImage?) {
        completion?(image)
        completion = nil
        retainSelf = nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Picks one contact with the system contact picker (no Contacts permission needed): used
/// to name a recognised person after someone in Contacts.
@MainActor
final class ContactPicker: NSObject, CNContactPickerDelegate {
    private var completion: ((CNContact?) -> Void)?
    private var retainSelf: ContactPicker?

    static func present(completion: @escaping (CNContact?) -> Void) {
        let picker = ContactPicker()
        picker.completion = completion
        picker.retainSelf = picker
        let controller = CNContactPickerViewController()
        controller.delegate = picker
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(controller, animated: true)
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let copy = ContactBox(contact: contact)
        MainActor.assumeIsolated { finish(copy.contact) }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func finish(_ contact: CNContact?) {
        completion?(contact)
        completion = nil
        retainSelf = nil
    }

    private struct ContactBox: @unchecked Sendable { let contact: CNContact }
}
