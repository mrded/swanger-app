import AppKit
import SwangerValidation
import SwiftUI

/// A plain-text JSON editor: monospaced, Tab indents by two spaces, Return keeps the indent, and
/// the bracket matching the one by the cursor is marked.
struct JSONEditor: NSViewRepresentable {
  @Binding var text: String
  /// Selects a range when its count changes, such as when an issue is chosen.
  let selectionRequest: SelectionRequest

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, selectionCount: selectionRequest.count)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.delegate = context.coordinator
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.string = text
    textView.setAccessibilityLabel("Payload")
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.text = $text
    if textView.string != text {
      // Through the text storage, so it's one change that can be undone.
      let whole = NSRange(location: 0, length: (textView.string as NSString).length)
      if textView.shouldChangeText(in: whole, replacementString: text) {
        textView.replaceCharacters(in: whole, with: text)
        textView.didChangeText()
      }
    }
    if selectionRequest.count != context.coordinator.selectionCount {
      context.coordinator.selectionCount = selectionRequest.count
      let length = (textView.string as NSString).length
      let lower = min(selectionRequest.range.lowerBound, length)
      let range = NSRange(
        location: lower, length: min(selectionRequest.range.count, length - lower))
      textView.window?.makeFirstResponder(textView)
      textView.setSelectedRange(range)
      textView.scrollRangeToVisible(range)
      if range.length > 0 { textView.showFindIndicator(for: range) }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var selectionCount: Int
    /// The brackets marked now, to unmark when the cursor moves.
    private var marked: [NSRange] = []
    /// The editor's own, so typing doesn't mark the read-only document as edited.
    private let undoManager = UndoManager()

    init(text: Binding<String>, selectionCount: Int) {
      self.text = text
      self.selectionCount = selectionCount
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      undoManager
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
      markBrackets(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      markBrackets(in: textView)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertTab(_:)): indent(textView)
      case #selector(NSResponder.insertBacktab(_:)): outdent(textView)
      case #selector(NSResponder.insertNewline(_:)): newline(textView)
      default: return false
      }
      return true
    }

    // MARK: Indenting

    /// Indents each selected line by two spaces, or, with the cursor in one line, inserts spaces
    /// to the next two-space stop.
    private func indent(_ textView: NSTextView) {
      let string = textView.string as NSString
      let selection = textView.selectedRange()
      let lines = string.lineRange(for: selection)
      let selectsLines =
        selection.length > 0
        && string.substring(with: selection).contains("\n")
      guard selectsLines else {
        let column =
          selection.location
          - string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        textView.insertText(
          String(repeating: " ", count: 2 - column % 2), replacementRange: selection)
        return
      }
      replaceLines(lines, in: textView) { "  " + $0 }
    }

    /// Takes up to two spaces from the start of each selected line.
    private func outdent(_ textView: NSTextView) {
      let string = textView.string as NSString
      let lines = string.lineRange(for: textView.selectedRange())
      replaceLines(lines, in: textView) { line in
        String(line.dropFirst(line.prefix(2).prefix { $0 == " " }.count))
      }
    }

    /// Changes each line in `range` with `change`, as one change that can be undone, and selects
    /// the lines.
    private func replaceLines(
      _ range: NSRange, in textView: NSTextView, _ change: (String) -> String
    ) {
      let old = (textView.string as NSString).substring(with: range)
      var lines = old.components(separatedBy: "\n")
      // The line range ends after a newline, so the last piece is empty and stays so.
      let trailing = lines.last == "" && lines.count > 1
      if trailing { lines.removeLast() }
      var new = lines.map(change).joined(separator: "\n")
      if trailing { new += "\n" }
      guard new != old, textView.shouldChangeText(in: range, replacementString: new) else { return }
      textView.replaceCharacters(in: range, with: new)
      textView.didChangeText()
      let length = (new as NSString).length - (trailing ? 1 : 0)
      textView.setSelectedRange(NSRange(location: range.location, length: length))
    }

    /// A new line with the same indent as this one, two spaces more after an opening bracket.
    /// Between a pair of brackets, the closing one goes on a line of its own.
    private func newline(_ textView: NSTextView) {
      let string = textView.string as NSString
      let selection = textView.selectedRange()
      let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
      let before = string.substring(
        with: NSRange(location: line.location, length: selection.location - line.location))
      let indent = String(before.prefix { $0 == " " || $0 == "\t" })
      let last = before.last { !$0.isWhitespace }
      let after =
        selection.upperBound < string.length
        ? string.substring(with: NSRange(location: selection.upperBound, length: 1)) : ""
      guard last == "{" || last == "[" else {
        textView.insertText("\n" + indent, replacementRange: selection)
        return
      }
      let inner = "\n" + indent + "  "
      let closes = (last == "{" && after == "}") || (last == "[" && after == "]")
      textView.insertText(inner + (closes ? "\n" + indent : ""), replacementRange: selection)
      if closes {
        let cursor = selection.location + (inner as NSString).length
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
      }
    }

    // MARK: Brackets

    /// Marks the bracket before or after the cursor and the one matching it.
    private func markBrackets(in textView: NSTextView) {
      guard let layoutManager = textView.layoutManager else { return }
      let length = (textView.string as NSString).length
      for range in marked where range.upperBound <= length {
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
      }
      marked = []
      let selection = textView.selectedRange()
      guard selection.length == 0 else { return }
      let text = textView.string
      for offset in [selection.location - 1, selection.location] where offset >= 0 {
        guard let match = JSONSourceMap.matchingBracket(at: offset, in: text) else { continue }
        marked = [NSRange(location: offset, length: 1), NSRange(location: match, length: 1)]
        for range in marked {
          layoutManager.addTemporaryAttribute(
            .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35),
            forCharacterRange: range)
        }
        return
      }
    }
  }
}
