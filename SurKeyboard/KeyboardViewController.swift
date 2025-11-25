//
//  KeyboardViewController.swift
//  SurKeyboard
//
//  Created by Mathe Eliel on 04/10/2025.
//

import UIKit
import AudioToolbox

// MARK: - Keyboard State
enum KeyboardMode {
    case letters
    case numbers
    case symbols
    case emojis
}

enum ShiftState {
    case off
    case on
    case capsLock
}

// MARK: - Settings Manager
class KeyboardSettings {
    static let shared = KeyboardSettings()
    private let hapticFeedbackKey = "hapticFeedbackEnabled"
    
    var isHapticFeedbackEnabled: Bool {
        get {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                return sharedDefaults.object(forKey: hapticFeedbackKey) as? Bool ?? true
            }
            return true
        }
        set {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                sharedDefaults.set(newValue, forKey: hapticFeedbackKey)
            }
        }
    }
    
    private init() {}
}

// MARK: - Key Button
class KeyButton: UIButton {
    var keyType: KeyType = .character("")
    var popupView: UIView?
    
    enum KeyType {
        case character(String)
        case shift
        case delete
        case numbers
        case symbols
        case space
        case returnKey
        case globe
        case emoji
        case microphone
        case letters  // Return to letters from emoji mode
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupButton()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }
    
    private func setupButton() {
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 0.5
        clipsToBounds = false
        titleLabel?.font = UIFont.systemFont(ofSize: 22, weight: .regular)
        adjustsImageWhenHighlighted = false
    }
    
    func showKeyPopup(in containerView: UIView, isDarkMode: Bool) {
        guard case .character(let char) = keyType, !char.isEmpty else { return }
        
        removeKeyPopup()
        
        let popup = UIView()
        popup.backgroundColor = isDarkMode ? UIColor(white: 0.4, alpha: 1.0) : .white
        popup.layer.cornerRadius = 8
        popup.layer.shadowColor = UIColor.black.cgColor
        popup.layer.shadowOffset = CGSize(width: 0, height: 2)
        popup.layer.shadowOpacity = 0.3
        popup.layer.shadowRadius = 4
        popup.clipsToBounds = false
        
        let label = UILabel()
        label.text = char.uppercased()
        label.font = UIFont.systemFont(ofSize: 36, weight: .regular)
        label.textColor = isDarkMode ? .white : .black
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.addSubview(label)
        
        popup.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(popup)
        
        let buttonFrame = convert(bounds, to: containerView)
        let popupWidth: CGFloat = max(bounds.width + 16, 48)
        let popupHeight: CGFloat = 60
        
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: popupWidth),
            popup.heightAnchor.constraint(equalToConstant: popupHeight),
            popup.centerXAnchor.constraint(equalTo: containerView.leadingAnchor, constant: buttonFrame.midX),
            popup.bottomAnchor.constraint(equalTo: containerView.topAnchor, constant: buttonFrame.minY - 4),
            label.centerXAnchor.constraint(equalTo: popup.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: popup.centerYAnchor)
        ])
        
        popupView = popup
    }
    
    func removeKeyPopup() {
        popupView?.removeFromSuperview()
        popupView = nil
    }
    
    func animatePress() {
        UIView.animate(withDuration: 0.05, animations: {
            self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            self.alpha = 0.8
        })
    }
    
    func animateRelease() {
        UIView.animate(withDuration: 0.1, animations: {
            self.transform = .identity
            self.alpha = 1.0
        })
    }
}

// MARK: - Keyboard View Controller
class KeyboardViewController: UIInputViewController {
    
    // MARK: - Properties
    private var keyboardView: UIView!
    private var rowStackViews: [UIStackView] = []
    private var hashLabel: UILabel!
    private var keyButtons: [KeyButton] = []
    
    private var currentMode: KeyboardMode = .letters
    private var shiftState: ShiftState = .off
    
    private let letterRows = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"]
    ]
    
    private let numberRows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"]
    ]
    
    private let symbolRows = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"]
    ]
    
    // Emoji data organized by categories (from Wikipedia List of emojis)
    private let emojiCategories: [(name: String, icon: String, emojis: [String])] = [
        ("Smileys", "face.smiling", [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
            "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗", "☺️", "😚",
            "😙", "🥲", "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
            "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏", "😒", "🙄",
            "😬", "🤥", "😌", "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕",
            "🤢", "🤮", "🤧", "🥵", "🥶", "🥴", "😵", "🤯", "🤠", "🥳",
            "🥸", "😎", "🤓", "🧐", "😕", "😟", "🙁", "☹️", "😮", "😯",
            "😲", "😳", "🥺", "😦", "😧", "😨", "😰", "😥", "😢", "😭",
            "😱", "😖", "😣", "😞", "😓", "😩", "😫", "🥱", "😤", "😡",
            "😠", "🤬", "😈", "👿", "💀", "☠️", "💩", "🤡", "👹", "👺"
        ]),
        ("Gestures", "hand.raised", [
            "👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞",
            "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👍",
            "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🤝",
            "🙏", "✍️", "💅", "🤳", "💪", "🦾", "🦿", "🦵", "🦶", "👂",
            "🦻", "👃", "🧠", "🫀", "🫁", "🦷", "🦴", "👀", "👁️", "👅",
            "👄", "👶", "🧒", "👦", "👧", "🧑", "👱", "👨", "🧔", "👩"
        ]),
        ("Hearts", "heart", [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
            "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "♥️",
            "😻", "💑", "👩‍❤️‍👨", "👨‍❤️‍👨", "👩‍❤️‍👩", "💏", "👩‍❤️‍💋‍👨", "👨‍❤️‍💋‍👨", "👩‍❤️‍💋‍👩", "🫂"
        ]),
        ("Animals", "hare", [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨",
            "🐯", "🦁", "🐮", "🐷", "🐽", "🐸", "🐵", "🙈", "🙉", "🙊",
            "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉",
            "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🪱", "🐛", "🦋", "🐌",
            "🐞", "🐜", "🪰", "🪲", "🪳", "🦟", "🦗", "🕷️", "🕸️", "🦂",
            "🐢", "🐍", "🦎", "🦖", "🦕", "🐙", "🦑", "🦐", "🦞", "🦀"
        ]),
        ("Food", "fork.knife", [
            "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈",
            "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦",
            "🥬", "🥒", "🌶️", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅", "🥔",
            "🍠", "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈",
            "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🦴", "🌭", "🍔", "🍟",
            "🍕", "🫓", "🥪", "🥙", "🧆", "🌮", "🌯", "🫔", "🥗", "🥘"
        ]),
        ("Activities", "sportscourt", [
            "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱",
            "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳",
            "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "🛷",
            "⛸️", "🥌", "🎿", "⛷️", "🏂", "🪂", "🏋️", "🤼", "🤸", "⛹️",
            "🤺", "🤾", "🏌️", "🏇", "⛷️", "🏊", "🤽", "🏄", "🚣", "🧗"
        ]),
        ("Travel", "car", [
            "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑", "🚒", "🚐",
            "🛻", "🚚", "🚛", "🚜", "🦯", "🦽", "🦼", "🛴", "🚲", "🛵",
            "🏍️", "🛺", "🚨", "🚔", "🚍", "🚘", "🚖", "🚡", "🚠", "🚟",
            "🚃", "🚋", "🚞", "🚝", "🚄", "🚅", "🚈", "🚂", "🚆", "🚇",
            "🚊", "🚉", "✈️", "🛫", "🛬", "🛩️", "💺", "🛰️", "🚀", "🛸"
        ]),
        ("Objects", "desktopcomputer", [
            "⌚", "📱", "📲", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🖲️", "🕹️",
            "🗜️", "💽", "💾", "💿", "📀", "📼", "📷", "📸", "📹", "🎥",
            "📽️", "🎞️", "📞", "☎️", "📟", "📠", "📺", "📻", "🎙️", "🎚️",
            "🎛️", "🧭", "⏱️", "⏲️", "⏰", "🕰️", "⌛", "⏳", "📡", "🔋",
            "🔌", "💡", "🔦", "🕯️", "🪔", "🧯", "🛢️", "💸", "💵", "💴"
        ]),
        ("Symbols", "star", [
            "💯", "💢", "💥", "💫", "💦", "💨", "🕳️", "💣", "💬", "👁️‍🗨️",
            "🗨️", "🗯️", "💭", "💤", "🔔", "🔕", "🎵", "🎶", "✅", "❌",
            "❎", "➕", "➖", "➗", "✖️", "♾️", "💲", "💱", "™️", "©️",
            "®️", "〰️", "➰", "➿", "🔚", "🔙", "🔛", "🔝", "🔜", "✔️",
            "☑️", "⭐", "🌟", "✨", "⚡", "🔥", "💧", "🌊", "🎉", "🎊"
        ]),
        ("Flags", "flag", [
            "🏳️", "🏴", "🏴‍☠️", "🏁", "🚩", "🎌", "🏳️‍🌈", "🏳️‍⚧️", "🇺🇳", "🇦🇫",
            "🇦🇱", "🇩🇿", "🇦🇸", "🇦🇩", "🇦🇴", "🇦🇮", "🇦🇶", "🇦🇬", "🇦🇷", "🇦🇲",
            "🇦🇼", "🇦🇺", "🇦🇹", "🇦🇿", "🇧🇸", "🇧🇭", "🇧🇩", "🇧🇧", "🇧🇾", "🇧🇪",
            "🇧🇿", "🇧🇯", "🇧🇲", "🇧🇹", "🇧🇴", "🇧🇦", "🇧🇼", "🇧🇷", "🇮🇴", "🇻🇬",
            "🇧🇳", "🇧🇬", "🇧🇫", "🇧🇮", "🇰🇭", "🇨🇲", "🇨🇦", "🇮🇨", "🇨🇻", "🇧🇶"
        ])
    ]
    
    private var emojiScrollView: UIScrollView?
    private var emojiCategoryButtons: [UIButton] = []
    private var currentEmojiCategoryIndex: Int = 0
    private var emojiCategoryBar: UIStackView?
    
    private var suggestionsView: UIView!
    private var isDarkMode: Bool {
        return textDocumentProxy.keyboardAppearance == .dark ||
               traitCollection.userInterfaceStyle == .dark
    }
    
    // MARK: - Haptic Feedback
    private var feedbackGenerator: UIImpactFeedbackGenerator?
    
    private func triggerHapticFeedback() {
        guard KeyboardSettings.shared.isHapticFeedbackEnabled else { return }
        feedbackGenerator?.impactOccurred()
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        feedbackGenerator?.prepare()
        
        setupKeyboardView()
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateColors()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardLayout()
    }
    
    override func updateViewConstraints() {
        super.updateViewConstraints()
    }
    
    override func textWillChange(_ textInput: UITextInput?) {
        // Prepare for text change
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        updateColors()
        updateShiftStateAfterTextChange()
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }
    
    // MARK: - Setup
    private func setupKeyboardView() {
        // Set a fixed height for the keyboard to ensure all elements are visible
        let keyboardHeight: CGFloat = 260
        
        keyboardView = UIView()
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)
        
        // Set the input view height with high priority
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        setupSuggestionsBar()
        setupKeyRows()
        setupBottomRow()
        setupHashBar()
        
        updateColors()
    }
    
    private func setupSuggestionsBar() {
        suggestionsView = UIView()
        suggestionsView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(suggestionsView)
        
        let suggestions = ["\"The\"", "the", "to"]
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        suggestionsView.addSubview(stackView)
        
        for suggestion in suggestions {
            let button = UIButton(type: .system)
            button.setTitle(suggestion, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            button.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
        
        NSLayoutConstraint.activate([
            suggestionsView.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            suggestionsView.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor),
            suggestionsView.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor),
            suggestionsView.heightAnchor.constraint(equalToConstant: 40),
            stackView.topAnchor.constraint(equalTo: suggestionsView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: suggestionsView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: suggestionsView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: suggestionsView.trailingAnchor, constant: -8)
        ])
    }
    
    private func setupKeyRows() {
        rowStackViews.removeAll()
        keyButtons.removeAll()
        
        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: suggestionsView.bottomAnchor, constant: 8),
            containerView.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 3),
            containerView.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -3)
        ])
        
        // Margin for second row (9 keys) to keep consistent key sizes
        let secondRowMargin: CGFloat = 18
        
        // Only create first two rows in the loop, handle third row separately
        for (index, row) in letterRows.enumerated() where index < 2 {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 6
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(rowStack)
            
            for character in row {
                let keyButton = createCharacterKey(character)
                rowStack.addArrangedSubview(keyButton)
                keyButtons.append(keyButton)
            }
            
            // Second row - add margins to center 9 keys
            let margin: CGFloat = index == 1 ? secondRowMargin : 0
            
            NSLayoutConstraint.activate([
                rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: margin),
                rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -margin),
                rowStack.heightAnchor.constraint(equalToConstant: 42)
            ])
            
            if index == 0 {
                rowStack.topAnchor.constraint(equalTo: containerView.topAnchor).isActive = true
            } else {
                rowStack.topAnchor.constraint(equalTo: rowStackViews[index - 1].bottomAnchor, constant: 12).isActive = true
            }
            
            rowStackViews.append(rowStack)
        }
        
        // Add third row with shift and delete
        createThirdRowWithSpecialKeys(containerView: containerView, characters: letterRows[2], leftKeyType: .shift, leftKeyTitle: nil)
        
        if let lastRow = rowStackViews.last {
            containerView.bottomAnchor.constraint(equalTo: lastRow.bottomAnchor).isActive = true
        }
    }
    
    /// Creates the third row with special keys on left and right, and character keys in the middle
    private func createThirdRowWithSpecialKeys(containerView: UIView, characters: [String], leftKeyType: KeyButton.KeyType, leftKeyTitle: String?) {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.distribution = .fill
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(rowStack)
        
        // Left special key (shift or symbols)
        let leftKey = createSpecialKey(type: leftKeyType, width: 42)
        if let title = leftKeyTitle {
            leftKey.setTitle(title, for: .normal)
        }
        rowStack.addArrangedSubview(leftKey)
        keyButtons.append(leftKey)
        
        // Letter/character keys container with equal distribution
        let lettersStack = UIStackView()
        lettersStack.axis = .horizontal
        lettersStack.distribution = .fillEqually
        lettersStack.spacing = 6
        lettersStack.translatesAutoresizingMaskIntoConstraints = false
        
        for character in characters {
            let keyButton = createCharacterKey(character)
            lettersStack.addArrangedSubview(keyButton)
            keyButtons.append(keyButton)
        }
        rowStack.addArrangedSubview(lettersStack)
        
        // Delete key
        let deleteKey = createSpecialKey(type: .delete, width: 42)
        rowStack.addArrangedSubview(deleteKey)
        keyButtons.append(deleteKey)
        
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            rowStack.heightAnchor.constraint(equalToConstant: 42),
            rowStack.topAnchor.constraint(equalTo: rowStackViews.last!.bottomAnchor, constant: 12)
        ])
        
        rowStackViews.append(rowStack)
    }
    
    private func setupBottomRow() {
        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.distribution = .fill
        bottomStack.spacing = 6
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(bottomStack)
        
        // "123" button (switches to numbers mode)
        let modeKey = createSpecialKey(type: .numbers, width: 42)
        modeKey.setTitle("123", for: .normal)
        modeKey.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        bottomStack.addArrangedSubview(modeKey)
        keyButtons.append(modeKey)
        
        // Emoji button
        let emojiKey = createSpecialKey(type: .emoji, width: 42)
        emojiKey.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        bottomStack.addArrangedSubview(emojiKey)
        keyButtons.append(emojiKey)
        
        // Space bar (flexible width)
        let spaceKey = createSpecialKey(type: .space, width: 0)
        spaceKey.setTitle("", for: .normal)
        bottomStack.addArrangedSubview(spaceKey)
        keyButtons.append(spaceKey)
        
        // Return key
        let returnKey = createSpecialKey(type: .returnKey, width: 88)
        returnKey.setImage(UIImage(systemName: "return"), for: .normal)
        returnKey.backgroundColor = UIColor.systemBlue
        returnKey.tintColor = .white
        bottomStack.addArrangedSubview(returnKey)
        keyButtons.append(returnKey)
        
        NSLayoutConstraint.activate([
            bottomStack.topAnchor.constraint(equalTo: rowStackViews.last!.bottomAnchor, constant: 12),
            bottomStack.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 3),
            bottomStack.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -3),
            bottomStack.heightAnchor.constraint(equalToConstant: 42),
            modeKey.widthAnchor.constraint(equalToConstant: 42),
            emojiKey.widthAnchor.constraint(equalToConstant: 42),
            returnKey.widthAnchor.constraint(equalToConstant: 88)
        ])
        
        rowStackViews.append(bottomStack)
    }
    
    private func setupHashBar() {
        let hashBar = UIView()
        hashBar.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(hashBar)
        
        // Emoji icon on the left (for display, emoji button is in bottom row)
        let emojiIcon = KeyButton()
        emojiIcon.keyType = .emoji
        emojiIcon.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiIcon.translatesAutoresizingMaskIntoConstraints = false
        emojiIcon.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        emojiIcon.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        emojiIcon.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpOutside, .touchCancel])
        hashBar.addSubview(emojiIcon)
        keyButtons.append(emojiIcon)
        
        // Hash label
        hashLabel = UILabel()
        hashLabel.text = "#0x4D4...734"
        hashLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        hashLabel.textAlignment = .center
        hashLabel.translatesAutoresizingMaskIntoConstraints = false
        hashBar.addSubview(hashLabel)
        
        // Microphone button
        let micButton = KeyButton()
        micButton.keyType = .microphone
        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        micButton.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpOutside, .touchCancel])
        hashBar.addSubview(micButton)
        keyButtons.append(micButton)
        
        NSLayoutConstraint.activate([
            hashBar.topAnchor.constraint(equalTo: rowStackViews.last!.bottomAnchor, constant: 8),
            hashBar.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor),
            hashBar.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor),
            hashBar.bottomAnchor.constraint(equalTo: keyboardView.bottomAnchor, constant: -4),
            hashBar.heightAnchor.constraint(equalToConstant: 36),
            
            emojiIcon.leadingAnchor.constraint(equalTo: hashBar.leadingAnchor, constant: 16),
            emojiIcon.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            emojiIcon.widthAnchor.constraint(equalToConstant: 36),
            emojiIcon.heightAnchor.constraint(equalToConstant: 36),
            
            hashLabel.centerXAnchor.constraint(equalTo: hashBar.centerXAnchor),
            hashLabel.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            
            micButton.trailingAnchor.constraint(equalTo: hashBar.trailingAnchor, constant: -16),
            micButton.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 36),
            micButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    
    // MARK: - Key Creation
    private func createCharacterKey(_ character: String) -> KeyButton {
        let keyButton = KeyButton()
        keyButton.keyType = .character(character)
        keyButton.setTitle(character, for: .normal)
        keyButton.translatesAutoresizingMaskIntoConstraints = false
        keyButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        
        keyButton.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        keyButton.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        keyButton.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpOutside, .touchCancel])
        
        return keyButton
    }
    
    private func createSpecialKey(type: KeyButton.KeyType, width: CGFloat) -> KeyButton {
        let keyButton = KeyButton()
        keyButton.keyType = type
        keyButton.translatesAutoresizingMaskIntoConstraints = false
        keyButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        
        switch type {
        case .shift:
            keyButton.setImage(UIImage(systemName: "shift"), for: .normal)
        case .delete:
            keyButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        case .numbers:
            keyButton.setTitle("123", for: .normal)
        case .symbols:
            keyButton.setTitle("#+=", for: .normal)
        case .globe:
            keyButton.setImage(UIImage(systemName: "globe"), for: .normal)
        case .space:
            keyButton.setTitle("space", for: .normal)
        case .returnKey:
            keyButton.setImage(UIImage(systemName: "return"), for: .normal)
        default:
            break
        }
        
        keyButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        if width > 0 {
            keyButton.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        
        keyButton.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        keyButton.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        keyButton.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpOutside, .touchCancel])
        
        return keyButton
    }
    
    // MARK: - Key Actions
    @objc private func keyTouchDown(_ sender: KeyButton) {
        sender.animatePress()
        triggerHapticFeedback()
        
        // Show popup for character keys
        if case .character = sender.keyType {
            sender.showKeyPopup(in: keyboardView, isDarkMode: isDarkMode)
        }
    }
    
    @objc private func keyTouchUp(_ sender: KeyButton) {
        sender.animateRelease()
        sender.removeKeyPopup()
    }
    
    @objc private func keyTapped(_ sender: KeyButton) {
        sender.animateRelease()
        sender.removeKeyPopup()
        
        switch sender.keyType {
        case .character(let char):
            let textToInsert: String
            if shiftState != .off {
                textToInsert = char.uppercased()
            } else {
                textToInsert = char
            }
            textDocumentProxy.insertText(textToInsert)
            
            // Auto-disable shift after typing (unless caps lock)
            if shiftState == .on {
                shiftState = .off
                updateShiftKeyAppearance()
            }
            
        case .shift:
            handleShiftTap()
            
        case .delete:
            textDocumentProxy.deleteBackward()
            
        case .numbers:
            toggleMode()
            
        case .symbols:
            toggleSymbols()
            
        case .space:
            textDocumentProxy.insertText(" ")
            
        case .returnKey:
            textDocumentProxy.insertText("\n")
            
        case .globe:
            // Handled by handleInputModeList
            break
            
        case .emoji:
            // Show custom emoji picker
            showEmojiPicker()
            
        case .microphone:
            // Microphone functionality - requires additional permissions
            break
            
        case .letters:
            // Return to letters mode from emoji picker
            currentMode = .letters
            rebuildKeyboardForMode(.letters)
        }
    }
    
    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let text = sender.titleLabel?.text else { return }
        let cleanText = text.replacingOccurrences(of: "\"", with: "")
        
        // Delete current word
        while let context = textDocumentProxy.documentContextBeforeInput,
              !context.isEmpty,
              let lastChar = context.last,
              !lastChar.isWhitespace {
            textDocumentProxy.deleteBackward()
        }
        
        textDocumentProxy.insertText(cleanText + " ")
        triggerHapticFeedback()
    }
    
    // MARK: - Emoji Picker
    private func showEmojiPicker() {
        currentMode = .emojis
        rebuildKeyboardForMode(.emojis)
    }
    
    private func setupEmojiPicker() {
        // Horizontal scroll view for emojis (takes up most of the space)
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        keyboardView.addSubview(scrollView)
        emojiScrollView = scrollView
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: suggestionsView.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 176)
        ])
        
        // Load initial category
        loadEmojiCategory(0)
        updateEmojiCategorySelection()
        
        // Bottom row for emoji picker
        setupEmojiBottomRow(topAnchor: scrollView.bottomAnchor)
    }
    
    private func loadEmojiCategory(_ index: Int) {
        guard let scrollView = emojiScrollView, index < emojiCategories.count else { return }
        
        currentEmojiCategoryIndex = index
        
        // Remove existing emoji buttons
        for subview in scrollView.subviews {
            subview.removeFromSuperview()
        }
        
        let emojis = emojiCategories[index].emojis
        let emojiSize: CGFloat = 44
        let horizontalSpacing: CGFloat = 4
        let verticalSpacing: CGFloat = 4
        let rows = 4
        let scrollViewHeight: CGFloat = 160
        let leftPadding: CGFloat = 8
        
        // Create emoji buttons in a grid that scrolls horizontally
        let columns = (emojis.count + rows - 1) / rows
        let contentWidth = leftPadding + CGFloat(columns) * (emojiSize + horizontalSpacing)
        
        for (i, emoji) in emojis.enumerated() {
            let row = i % rows
            let col = i / rows
            
            let button = UIButton(type: .system)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 32)
            button.addTarget(self, action: #selector(emojiTapped(_:)), for: .touchUpInside)
            button.frame = CGRect(
                x: leftPadding + CGFloat(col) * (emojiSize + horizontalSpacing),
                y: CGFloat(row) * (emojiSize + verticalSpacing),
                width: emojiSize,
                height: emojiSize
            )
            scrollView.addSubview(button)
        }
        
        scrollView.contentSize = CGSize(width: contentWidth, height: scrollViewHeight)
        scrollView.setContentOffset(.zero, animated: false)
        
        updateEmojiCategorySelection()
    }
    
    @objc private func emojiCategoryTapped(_ sender: UIButton) {
        loadEmojiCategory(sender.tag)
        triggerHapticFeedback()
    }
    
    @objc private func emojiTapped(_ sender: UIButton) {
        guard let emoji = sender.titleLabel?.text else { return }
        textDocumentProxy.insertText(emoji)
        triggerHapticFeedback()
    }
    
    private func updateEmojiCategorySelection() {
        let selectedColor = isDarkMode ? UIColor.white : UIColor.systemBlue
        let normalColor = isDarkMode ? UIColor.gray : UIColor.gray
        
        for (index, button) in emojiCategoryButtons.enumerated() {
            button.tintColor = index == currentEmojiCategoryIndex ? selectedColor : normalColor
        }
    }
    
    private func setupEmojiBottomRow(topAnchor: NSLayoutYAxisAnchor) {
        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.distribution = .fill
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(bottomStack)
        
        // ABC button (return to letters)
        let abcKey = createSpecialKey(type: .letters, width: 50)
        abcKey.setTitle("ABC", for: .normal)
        abcKey.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        bottomStack.addArrangedSubview(abcKey)
        keyButtons.append(abcKey)
        
        // Category icons in the middle
        let categoryStack = UIStackView()
        categoryStack.axis = .horizontal
        categoryStack.distribution = .fillEqually
        categoryStack.spacing = 2
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Clear and rebuild category buttons
        emojiCategoryButtons.removeAll()
        
        // Add category icons to bottom bar
        for (index, category) in emojiCategories.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: category.icon), for: .normal)
            button.tag = index
            button.tintColor = index == currentEmojiCategoryIndex ? (isDarkMode ? .white : .systemBlue) : .gray
            button.addTarget(self, action: #selector(emojiCategoryTapped(_:)), for: .touchUpInside)
            categoryStack.addArrangedSubview(button)
            emojiCategoryButtons.append(button)
        }
        
        bottomStack.addArrangedSubview(categoryStack)
        
        // Delete key
        let deleteKey = createSpecialKey(type: .delete, width: 50)
        bottomStack.addArrangedSubview(deleteKey)
        keyButtons.append(deleteKey)
        
        NSLayoutConstraint.activate([
            bottomStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bottomStack.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 3),
            bottomStack.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -3),
            bottomStack.heightAnchor.constraint(equalToConstant: 36),
            abcKey.widthAnchor.constraint(equalToConstant: 50),
            deleteKey.widthAnchor.constraint(equalToConstant: 50)
        ])
        
        rowStackViews.append(bottomStack)
    }
    
    // MARK: - Mode Handling
    private func handleShiftTap() {
        switch shiftState {
        case .off:
            shiftState = .on
        case .on:
            shiftState = .capsLock
        case .capsLock:
            shiftState = .off
        }
        updateShiftKeyAppearance()
        updateKeyLabels()
    }
    
    private func updateShiftKeyAppearance() {
        for button in keyButtons {
            if case .shift = button.keyType {
                switch shiftState {
                case .off:
                    button.setImage(UIImage(systemName: "shift"), for: .normal)
                    button.backgroundColor = isDarkMode ? UIColor(white: 0.35, alpha: 1.0) : UIColor(white: 0.85, alpha: 1.0)
                    button.tintColor = isDarkMode ? .white : .black
                case .on:
                    button.setImage(UIImage(systemName: "shift.fill"), for: .normal)
                    button.backgroundColor = .white
                    button.tintColor = .black
                case .capsLock:
                    button.setImage(UIImage(systemName: "capslock.fill"), for: .normal)
                    button.backgroundColor = .white
                    button.tintColor = .black
                }
            }
        }
    }
    
    private func updateKeyLabels() {
        for button in keyButtons {
            if case .character(let char) = button.keyType {
                let displayText = shiftState != .off ? char.uppercased() : char.lowercased()
                button.setTitle(displayText, for: .normal)
            }
        }
    }
    
    private func toggleMode() {
        if currentMode == .letters || currentMode == .emojis {
            currentMode = .numbers
            rebuildKeyboardForMode(.numbers)
        } else {
            currentMode = .letters
            rebuildKeyboardForMode(.letters)
        }
    }
    
    private func toggleSymbols() {
        if currentMode == .numbers {
            currentMode = .symbols
            rebuildKeyboardForMode(.symbols)
        } else if currentMode == .symbols {
            currentMode = .numbers
            rebuildKeyboardForMode(.numbers)
        }
    }
    
    private func rebuildKeyboardForMode(_ mode: KeyboardMode) {
        // Remove existing key rows (but keep suggestions and hash bar)
        for stackView in rowStackViews {
            stackView.removeFromSuperview()
        }
        rowStackViews.removeAll()
        keyButtons.removeAll()
        
        // Remove emoji picker specific views
        emojiScrollView?.removeFromSuperview()
        emojiScrollView = nil
        emojiCategoryBar?.removeFromSuperview()
        emojiCategoryBar = nil
        emojiCategoryButtons.removeAll()
        
        // Rebuild keys based on mode
        if mode == .emojis {
            setupEmojiPicker()
        } else {
            setupKeyRowsForMode(mode)
            setupBottomRowForMode(mode)
        }
        updateColors()
    }
    
    private func setupKeyRowsForMode(_ mode: KeyboardMode) {
        let rows: [[String]]
        switch mode {
        case .letters:
            rows = letterRows
        case .numbers:
            rows = numberRows
        case .symbols:
            rows = symbolRows
        case .emojis:
            // Emoji mode is handled separately
            return
        }
        
        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: suggestionsView.bottomAnchor, constant: 8),
            containerView.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 3),
            containerView.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -3)
        ])
        
        // Margin for second row (9 keys)
        let secondRowMargin: CGFloat = 18
        
        for (index, row) in rows.enumerated() {
            // Skip third row - we'll handle it separately with special keys
            if index == 2 {
                continue
            }
            
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 6
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(rowStack)
            
            for character in row {
                let keyButton = createCharacterKey(character)
                rowStack.addArrangedSubview(keyButton)
                keyButtons.append(keyButton)
            }
            
            // Second row - add margins to center 9 keys (only for letters mode)
            let margin: CGFloat = (mode == .letters && index == 1) ? secondRowMargin : 0
            
            NSLayoutConstraint.activate([
                rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: margin),
                rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -margin),
                rowStack.heightAnchor.constraint(equalToConstant: 42)
            ])
            
            if rowStackViews.isEmpty {
                rowStack.topAnchor.constraint(equalTo: containerView.topAnchor).isActive = true
            } else {
                rowStack.topAnchor.constraint(equalTo: rowStackViews.last!.bottomAnchor, constant: 12).isActive = true
            }
            
            rowStackViews.append(rowStack)
        }
        
        // Add third row with special keys
        if mode == .letters {
            createThirdRowWithSpecialKeys(containerView: containerView, characters: letterRows[2], leftKeyType: .shift, leftKeyTitle: nil)
        } else {
            let title = mode == .numbers ? "#+=": "123"
            createThirdRowWithSpecialKeys(containerView: containerView, characters: rows[2], leftKeyType: .symbols, leftKeyTitle: title)
        }
        
        if let lastRow = rowStackViews.last {
            containerView.bottomAnchor.constraint(equalTo: lastRow.bottomAnchor).isActive = true
        }
    }
    
    private func setupBottomRowForMode(_ mode: KeyboardMode) {
        // Emoji mode has its own bottom row setup
        if mode == .emojis {
            return
        }
        
        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.distribution = .fill
        bottomStack.spacing = 6
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(bottomStack)
        
        // Mode switch key ("123" or "ABC")
        let modeKey = createSpecialKey(type: .numbers, width: 42)
        modeKey.setTitle(mode == .letters ? "123" : "ABC", for: .normal)
        modeKey.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        bottomStack.addArrangedSubview(modeKey)
        keyButtons.append(modeKey)
        
        // Emoji button
        let emojiKey = createSpecialKey(type: .emoji, width: 42)
        emojiKey.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        bottomStack.addArrangedSubview(emojiKey)
        keyButtons.append(emojiKey)
        
        // Space bar (flexible width)
        let spaceKey = createSpecialKey(type: .space, width: 0)
        spaceKey.setTitle("", for: .normal)
        bottomStack.addArrangedSubview(spaceKey)
        keyButtons.append(spaceKey)
        
        // Return key
        let returnKey = createSpecialKey(type: .returnKey, width: 88)
        returnKey.setImage(UIImage(systemName: "return"), for: .normal)
        returnKey.backgroundColor = UIColor.systemBlue
        returnKey.tintColor = .white
        bottomStack.addArrangedSubview(returnKey)
        keyButtons.append(returnKey)
        
        NSLayoutConstraint.activate([
            bottomStack.topAnchor.constraint(equalTo: rowStackViews.last!.bottomAnchor, constant: 12),
            bottomStack.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 3),
            bottomStack.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -3),
            bottomStack.heightAnchor.constraint(equalToConstant: 42),
            modeKey.widthAnchor.constraint(equalToConstant: 42),
            emojiKey.widthAnchor.constraint(equalToConstant: 42),
            returnKey.widthAnchor.constraint(equalToConstant: 88)
        ])
        
        rowStackViews.append(bottomStack)
    }
    
    // MARK: - Auto-Shift
    private func updateShiftStateAfterTextChange() {
        guard currentMode == .letters else { return }
        
        // Auto-capitalize after sentence ending
        if let context = textDocumentProxy.documentContextBeforeInput {
            let trimmed = context.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
                if shiftState == .off {
                    shiftState = .on
                    updateShiftKeyAppearance()
                    updateKeyLabels()
                }
            }
        } else {
            // Beginning of document
            if shiftState == .off {
                shiftState = .on
                updateShiftKeyAppearance()
                updateKeyLabels()
            }
        }
    }
    
    // MARK: - Layout & Colors
    private func updateKeyboardLayout() {
        // Adjust layout based on keyboard size if needed
    }
    
    private func updateColors() {
        let backgroundColor = isDarkMode ? UIColor(white: 0.15, alpha: 1.0) : UIColor(white: 0.85, alpha: 1.0)
        let keyBackgroundColor = isDarkMode ? UIColor(white: 0.35, alpha: 1.0) : .white
        let specialKeyBackgroundColor = isDarkMode ? UIColor(white: 0.25, alpha: 1.0) : UIColor(white: 0.85, alpha: 1.0)
        let textColor = isDarkMode ? UIColor.white : UIColor.black
        
        keyboardView.backgroundColor = backgroundColor
        view.backgroundColor = backgroundColor
        
        for button in keyButtons {
            button.setTitleColor(textColor, for: .normal)
            button.tintColor = textColor
            
            switch button.keyType {
            case .character:
                button.backgroundColor = keyBackgroundColor
            case .shift:
                // Handle shift colors based on state
                if shiftState == .off {
                    button.backgroundColor = specialKeyBackgroundColor
                    button.tintColor = textColor
                } else {
                    // For on/capsLock state, use white background with black icon
                    button.backgroundColor = .white
                    button.tintColor = .black
                }
            case .delete, .numbers, .symbols, .letters:
                button.backgroundColor = specialKeyBackgroundColor
            case .space:
                button.backgroundColor = keyBackgroundColor
            case .returnKey:
                button.backgroundColor = UIColor.systemBlue
                button.tintColor = .white
            case .globe, .emoji, .microphone:
                button.backgroundColor = .clear
            }
        }
        
        hashLabel?.textColor = isDarkMode ? UIColor(white: 0.6, alpha: 1.0) : UIColor(white: 0.5, alpha: 1.0)
        
        // Update suggestions bar
        for subview in suggestionsView.subviews {
            if let stackView = subview as? UIStackView {
                for arrangedSubview in stackView.arrangedSubviews {
                    if let button = arrangedSubview as? UIButton {
                        button.setTitleColor(textColor, for: .normal)
                    }
                }
            }
        }
    }
}
