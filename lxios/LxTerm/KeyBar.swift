import SwiftTerm
import UIKit

/// The row above the keyboard: keys a phone keyboard lacks (Esc, Ctrl, Tab, arrows,
/// common symbols) and a key that really hides the keyboard. Replaces SwiftTerm's own
/// accessory, whose last key swapped in a function-key keyboard instead of hiding.
final class KeyBar: UIInputView {
    private weak var session: Session?
    private let ctrlButton = UIButton(type: .system)

    init(session: Session) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let keys: [(String, String, [UInt8])] = [
            ("esc", "", [0x1b]), ("ctrl", "", []), ("tab", "arrow.right.to.line", [0x09]),
            ("up", "arrow.up", Array("\u{1b}[A".utf8)), ("down", "arrow.down", Array("\u{1b}[B".utf8)),
            ("left", "arrow.left", Array("\u{1b}[D".utf8)), ("right", "arrow.right", Array("\u{1b}[C".utf8)),
            ("|", "", Array("|".utf8)), ("~", "", Array("~".utf8)), ("/", "", Array("/".utf8)),
            ("-", "", Array("-".utf8)), ("_", "", Array("_".utf8)), ("^C", "", [0x03]), ("^D", "", [0x04]),
        ]
        for (title, symbol, bytes) in keys {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.gray()
            cfg.cornerStyle = .medium
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
            if symbol.isEmpty {
                cfg.attributedTitle = AttributedString(title == "ctrl" ? "Ctrl" : title == "esc" ? "Esc" : title,
                                                       attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .medium)]))
            } else {
                cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            }
            b.configuration = cfg
            b.accessibilityLabel = title
            if title == "ctrl" {
                ctrlButton.configuration = cfg
                ctrlButton.accessibilityLabel = "Control"
                ctrlButton.addAction(UIAction { [weak self] _ in self?.toggleCtrl() }, for: .touchUpInside)
                stack.addArrangedSubview(ctrlButton)
                continue
            }
            b.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.session?.sendKeys(bytes)
            }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }

        let fn = UIButton(type: .system)                          // F1-F12, in a menu: the row stays as it is
        var fc = UIButton.Configuration.gray()
        fc.cornerStyle = .medium
        fc.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
        fc.attributedTitle = AttributedString("Fn", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .medium)]))
        fn.configuration = fc
        fn.accessibilityLabel = String(localized: "Function keys")
        fn.showsMenuAsPrimaryAction = true
        fn.menu = UIMenu(title: "", options: .displayInline, children: KeyBar.functionKeys.enumerated().map { i, seq in
            UIAction(title: "F\(i + 1)") { [weak self] _ in self?.session?.sendKeys(Array(seq.utf8)) }
        } + [UIAction(title: String(localized: "Home")) { [weak self] _ in self?.session?.sendKeys(Array("\u{1b}[H".utf8)) },
             UIAction(title: String(localized: "End")) { [weak self] _ in self?.session?.sendKeys(Array("\u{1b}[F".utf8)) },
             UIAction(title: String(localized: "Page Up")) { [weak self] _ in self?.session?.sendKeys(Array("\u{1b}[5~".utf8)) },
             UIAction(title: String(localized: "Page Down")) { [weak self] _ in self?.session?.sendKeys(Array("\u{1b}[6~".utf8)) }])
        fn.preferredMenuElementOrder = .fixed
        stack.addArrangedSubview(fn)

        let hide = UIButton(type: .system)
        var hc = UIButton.Configuration.filled()
        hc.cornerStyle = .medium
        hc.image = UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        hc.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        hide.configuration = hc
        hide.accessibilityLabel = String(localized: "Hide keyboard")
        hide.addAction(UIAction { [weak self] _ in _ = self?.session?.view.resignFirstResponder() }, for: .touchUpInside)
        hide.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(hide)
        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What xterm sends for F1-F12.
    static let functionKeys = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~",
                               "\u{1b}[18~", "\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]

    private func toggleCtrl() {
        guard let s = session else { return }
        s.ctrlArmed.toggle()
        updateCtrl()
    }

    func updateCtrl() {
        guard var cfg = ctrlButton.configuration else { return }
        cfg.baseBackgroundColor = session?.ctrlArmed == true ? .tintColor : nil
        cfg.baseForegroundColor = session?.ctrlArmed == true ? .white : nil
        ctrlButton.configuration = cfg
    }
}
