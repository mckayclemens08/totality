#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import TotalityReader

private typealias Paragraph = DocText.Paragraph
private typealias Run = DocText.Run

/// These drive a real text view, because the bugs here live between the view and the doc.
@MainActor
@Suite("Doc editor")
struct DocEditorTests {
    private func editor(_ doc: DocText) -> (DocEditorController, NSTextView) {
        let controller = DocEditorController()
        let view = NSTextView()
        view.delegate = controller
        controller.load(doc)
        controller.attach(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        return (controller, view)
    }

    private func type(_ text: String, in view: NSTextView) {
        view.insertText(text, replacementRange: view.selectedRange())
    }

    @Test("Everything a doc can hold survives the screen and back")
    func roundTrip() {
        let doc = DocText(paragraphs: [
            Paragraph(.heading1, runs: [Run("Trip")]),
            Paragraph(.body, runs: [Run("Pack "), Run("light", bold: true), Run(" and "), Run("early", italic: true)]),
            Paragraph(.bullet, runs: [Run("Passport")]),
            Paragraph(.bullet, runs: []),
            Paragraph(.numbered, runs: [Run("First")]),
            Paragraph(.numbered, runs: [Run("Second", bold: true, italic: true)]),
            Paragraph(.heading2, runs: []),
            Paragraph(.body, runs: [Run("Map", link: URL(string: "https://example.com"))]),
        ])
        #expect(DocRendering.doc(from: DocRendering.attributed(doc)) == doc)
    }

    @Test("A heading chosen on an empty line stays, and what's typed takes it")
    func headingOnEmptyDoc() {
        let (controller, view) = editor(DocText())
        controller.setStyle(.heading1)
        #expect(controller.activeStyle == .heading1)
        #expect(controller.document.paragraphs == [Paragraph(.heading1, runs: [])])
        type("Plans", in: view)
        #expect(controller.document.paragraphs == [Paragraph(.heading1, runs: [Run("Plans")])])
    }

    @Test("Return after a heading goes back to body text")
    func returnAfterHeading() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.heading1, runs: [Run("Plans")])]))
        view.insertNewline(nil)
        type("Next", in: view)
        #expect(controller.document.paragraphs == [
            Paragraph(.heading1, runs: [Run("Plans")]), Paragraph(.body, runs: [Run("Next")]),
        ])
    }

    @Test("Return at the start of a heading pushes it down and keeps it a heading")
    func returnBeforeHeading() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.heading1, runs: [Run("Plans")])]))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertNewline(nil)
        #expect(controller.document.paragraphs == [Paragraph(), Paragraph(.heading1, runs: [Run("Plans")])])
    }

    @Test("Return continues a list, and Return on an empty item ends it")
    func returnInList() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.numbered, runs: [Run("One")])]))
        view.insertNewline(nil)
        #expect(view.string == "1.\tOne\n2.\t")
        type("Two", in: view)
        view.insertNewline(nil)
        view.insertNewline(nil)
        type("After", in: view)
        #expect(controller.document.paragraphs == [
            Paragraph(.numbered, runs: [Run("One")]), Paragraph(.numbered, runs: [Run("Two")]),
            Paragraph(.body, runs: [Run("After")]),
        ])
    }

    @Test("Return in the middle of a list item splits it where the caret is")
    func returnMidItem() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.bullet, runs: [Run("Passport")])]))
        view.setSelectedRange(NSRange(location: "•\tPass".utf16.count, length: 0))
        view.insertNewline(nil)
        #expect(controller.document.paragraphs == [
            Paragraph(.bullet, runs: [Run("Pass")]), Paragraph(.bullet, runs: [Run("port")]),
        ])
        #expect(view.selectedRange().location == "•\tPass\n•\t".utf16.count)
    }

    @Test("Backspace at the start of an item takes away the bullet, not the words")
    func backspaceOnMarker() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.bullet, runs: [Run("Passport")])]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        #expect(controller.document.paragraphs == [Paragraph(.body, runs: [Run("Passport")])])
    }

    @Test("Deleting a line renumbers the list")
    func deletingRenumbers() {
        let (controller, view) = editor(DocText(paragraphs: [
            Paragraph(.numbered, runs: [Run("One")]), Paragraph(.numbered, runs: [Run("Two")]),
            Paragraph(.numbered, runs: [Run("Three")]),
        ]))
        let text = view.string as NSString
        view.setSelectedRange(NSRange(location: text.range(of: "One").location, length: text.range(of: "Three").location - text.range(of: "One").location - "3.\t".utf16.count))
        view.deleteBackward(nil)
        #expect(controller.document.paragraphs.map(\.text) == ["Three"])
        #expect(view.string == "1.\tThree")
    }

    @Test("A pasted block of lines stays as lines, and a bullet can't be typed into")
    func pasteAndCaret() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.bullet, runs: [Run("One")])]))
        type("\nTwo\nThree", in: view)
        #expect(controller.document.paragraphs.map(\.text) == ["One", "Two", "Three"])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.selectedRange().location == 2)
    }

    @Test("Bold applies to a selection, marks it for saving, and comes off again")
    func boldSelection() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.body, runs: [Run("Pack light")])]))
        let before = controller.revision
        view.setSelectedRange(NSRange(location: 5, length: 5))
        controller.toggleBold()
        #expect(controller.document.paragraphs[0].runs == [Run("Pack "), Run("light", bold: true)])
        #expect(controller.revision > before)
        #expect(controller.isBold)
        controller.toggleBold()
        #expect(controller.document.paragraphs[0].runs == [Run("Pack light")])
    }

    @Test("Bold with no selection applies to what's typed next")
    func boldTyping() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.body, runs: [Run("Pack ")])]))
        controller.toggleBold()
        type("light", in: view)
        #expect(controller.document.paragraphs[0].runs == [Run("Pack "), Run("light", bold: true)])
    }

    @Test("A link needs a real address, gets a scheme if it has none, and can be removed")
    func links() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(.body, runs: [Run("Map")])]))
        view.setSelectedRange(NSRange(location: 0, length: 3))
        controller.setLink(address: "javascript:alert(1)")
        #expect(controller.document.paragraphs[0].runs == [Run("Map")])
        controller.setLink(address: "example.com")
        #expect(controller.document.paragraphs[0].runs == [Run("Map", link: URL(string: "https://example.com"))])
        controller.setLink(address: "")
        #expect(controller.document.paragraphs[0].runs == [Run("Map")])
    }

    @Test("What was typed is still there for the last save after the view has gone")
    func lastSave() {
        let controller = DocEditorController()
        controller.load(DocText(paragraphs: [Paragraph(runs: [Run("original")])]))
        autoreleasepool {
            let view = NSTextView()
            view.delegate = controller
            controller.attach(view)
            view.setSelectedRange(NSRange(location: 8, length: 0))
            view.insertText(" and more", replacementRange: view.selectedRange())
        }
        #expect(controller.document.plainText == "original and more")
    }

    @Test("A new view picks up what the last one held")
    func reattach() {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(runs: [Run("Pack")])]))
        type(" light", in: view)
        let next = NSTextView()
        controller.attach(next)
        #expect(next.string == "Pack light")
    }

    @Test("A link that came in some other way can't open or be saved")
    func foreignLinks() throws {
        let (controller, view) = editor(DocText(paragraphs: [Paragraph(runs: [Run("Map")])]))
        let evil = try #require(URL(string: "x-evil://run"))
        view.textStorage?.addAttribute(.link, value: evil, range: NSRange(location: 0, length: 3))
        view.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(controller.currentLink == nil)
        #expect(controller.document.paragraphs[0].runs == [Run("Map")])
    }

    @Test("Loading a doc before the view exists shows it once the view arrives")
    func loadBeforeAttach() {
        let controller = DocEditorController()
        controller.load(DocText(paragraphs: [Paragraph(.body, runs: [Run("Waiting")])]))
        #expect(controller.document.plainText == "Waiting")
        let view = NSTextView()
        controller.attach(view)
        #expect(view.string == "Waiting")
    }
}
#endif
