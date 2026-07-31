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
    private let autocorrectKey = "autocorrectEnabled"
    private let predictiveTextKey = "predictiveTextEnabled"
    private let doubleSpacePeriodKey = "doubleSpacePeriodEnabled"

    private func flag(_ key: String, default defaultValue: Bool) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") else { return defaultValue }
        return sharedDefaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private func setFlag(_ key: String, _ value: Bool) {
        UserDefaults(suiteName: "group.com.ordo.sure.Sur")?.set(value, forKey: key)
    }

    var isHapticFeedbackEnabled: Bool {
        get { flag(hapticFeedbackKey, default: true) }
        set { setFlag(hapticFeedbackKey, newValue) }
    }

    var isAutocorrectEnabled: Bool {
        get { flag(autocorrectKey, default: true) }
        set { setFlag(autocorrectKey, newValue) }
    }

    var isPredictiveTextEnabled: Bool {
        get { flag(predictiveTextKey, default: true) }
        set { setFlag(predictiveTextKey, newValue) }
    }

    var isDoubleSpacePeriodEnabled: Bool {
        get { flag(doubleSpacePeriodKey, default: true) }
        set { setFlag(doubleSpacePeriodKey, newValue) }
    }

    private init() {}
}

// MARK: - Key Button
class KeyButton: UIButton {
    var keyType: KeyType = .character("")
    private var popupView: UIView?
    private var popupLabel: UILabel?

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
        case check     // Check icon on hash bar
        case proofLink // Send the message + a link to its on-chain proof
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
    
    /// Shows the enlarged character preview above the key, creating the popup
    /// view once and reusing it on every subsequent press of this SAME key
    /// instance (e.g. a double letter). Building a fresh UIView + UILabel and
    /// running Auto Layout on every single keystroke was measurable overhead —
    /// on a 120Hz/ProMotion display the frame budget is ~8.3ms, so per-tap
    /// allocation cost that's invisible at 60Hz shows up as dropped frames.
    /// The button itself is recreated on every keyboard mode switch, so this
    /// cache is automatically bounded to a single mode's lifetime — see
    /// discardKeyPopup(), which must be called before that happens.
    func showKeyPopup(in containerView: UIView, isDarkMode: Bool) {
        guard case .character(let char) = keyType, !char.isEmpty else { return }

        let popup: UIView
        let label: UILabel
        if let existingPopup = popupView, let existingLabel = popupLabel {
            popup = existingPopup
            label = existingLabel
        } else {
            popup = UIView()
            popup.layer.cornerRadius = 8
            popup.layer.shadowColor = UIColor.black.cgColor
            popup.layer.shadowOffset = CGSize(width: 0, height: 2)
            popup.layer.shadowOpacity = 0.3
            popup.layer.shadowRadius = 4
            popup.clipsToBounds = false
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.isUserInteractionEnabled = false

            label = UILabel()
            label.font = UIFont.systemFont(ofSize: 36, weight: .regular)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            popup.addSubview(label)

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
            popupLabel = label
        }

        popup.backgroundColor = isDarkMode ? UIColor(white: 0.4, alpha: 1.0) : .white
        label.text = char.uppercased()
        label.textColor = isDarkMode ? .white : .black
        popup.isHidden = false
        containerView.bringSubviewToFront(popup)
    }

    /// Hides the popup (cheap) without tearing it down — showKeyPopup() will
    /// reuse it next time this key is pressed.
    func removeKeyPopup() {
        popupView?.isHidden = true
    }

    /// Hard-removes the cached popup. Must be called before this button is
    /// discarded (e.g. on a keyboard mode rebuild) — the popup lives in the
    /// keyboard's view (a sibling of this button, not a subview of it), so it
    /// would otherwise be orphaned there instead of going away with the button.
    func discardKeyPopup() {
        popupView?.removeFromSuperview()
        popupView = nil
        popupLabel = nil
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

    // Shared app-group + the key under which sessions awaiting on-chain
    // attestation are queued for the host app to pick up.
    private static let appGroupID = "group.com.ordo.sure.Sur"
    private static let pendingAttestKey = "sur.attest.pendingSessionIds"
    /// Best-effort marker the host app reads to know whether Full Access is
    /// currently granted, so it can nudge the user instead of them discovering
    /// it only after a session silently fails to save. Without Full Access this
    /// extension can read the shared container but NOT write to it, so we can
    /// only ever positively confirm "granted" here — if access is later
    /// revoked, this stays stale at true until the extension is opened again
    /// with access restored, which is an acceptable gap for a UX hint.
    private static let fullAccessKey = "keyboard.hasFullAccess"
    /// Set (from the "Don't show this again" checkbox) once the first-run
    /// explainer has been dismissed. The app's Settings tab exposes a "Show
    /// keyboard tutorial again" toggle bound to the same key — the overlay
    /// itself can't offer an "uncheck" control since it disappears once
    /// dismissed.
    private static let tutorialDismissedKey = "keyboard.tutorial.dismissed"
    private var tutorialOverlayView: KeyboardTutorialOverlay?

    // MARK: - Properties
    private var keyboardView: UIView!
    private var rowStackViews: [UIStackView] = []
    private var hashLabel: UILabel!
    private var hashBarView: UIView?  // Reference to hash bar so it persists across mode changes
    private var keyButtons: [KeyButton] = []
    
    private var currentMode: KeyboardMode = .letters
    private var shiftState: ShiftState = .off
    
    // Delete key repeat timer
    private var deleteTimer: Timer?
    private var deleteRepeatInterval: TimeInterval = 0.1 // Initial repeat rate
    
    // Keystroke logging
    private let keystrokeLogger = KeystrokeLogger.shared
    private var lastKeyPressLocation: CGPoint = .zero

    // Predictive text / autocorrect (fully on-device via UITextChecker — no
    // network, no Full Access needed).
    private let textChecker = UITextChecker()
    private var suggestionButtons: [UIButton] = []
    /// The word just autocorrected, kept only long enough to offer "as typed" as
    /// a tappable revert; cleared once the user moves past it.
    private var lastAutocorrect: (typed: String, corrected: String)?

    // Double-space-for-period
    private var lastSpaceTapTime: Date?

    // Auto-return-to-letters: typing one of autoReturnToLettersPunctuation from
    // the numbers/symbols pad arms this; the next space consumes it, switches
    // back to letters, and (for true sentence-enders) capitalizes the next
    // letter. Cleared by any other key in between (see keyTapped).
    private var pendingReturnToLettersAfterSpace = false
    private var pendingCapitalizeAfterReturn = false
    private static let autoReturnToLettersPunctuation: Set<String> = [".", ",", "!", "?", ";", ":"]
    private static let autoCapitalizePunctuation: Set<String> = [".", "!", "?"]

    // Shift: a second tap within this window while shift is already on engages
    // caps lock (matches stock iOS); a slower second tap just toggles shift off.
    private var lastShiftTapTime: Date?

    // Delete key acceleration: char-by-char, then whole words after a hold.
    private var deleteHoldStartTime: Date?
    private static let deleteWordAccelerationDelay: TimeInterval = 1.5

    // Long-press-for-accents (e.g. holding "e" for é è ê ë). Implemented on the
    // key button's existing UIControl touch events (touchDown / touchDragInside
    // / touchDragOutside / touchUp*) rather than a separate gesture recognizer,
    // so it can never double-fire alongside normal tap handling.
    private var longPressTimer: Timer?
    private var accentPopupKey: KeyButton?
    private var accentPopupView: UIView?
    private var accentPopupSegments: [(frame: CGRect, char: String)] = []
    private var accentPopupSelectedIndex: Int = 0
    private static let longPressDuration: TimeInterval = 0.35
    private let accentVariants: [String: [String]] = [
        "a": ["a", "à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "e": ["e", "è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["i", "ì", "í", "î", "ï", "ī", "į"],
        "o": ["o", "ò", "ó", "ô", "ö", "õ", "ø", "ō", "œ"],
        "u": ["u", "ù", "ú", "û", "ü", "ū"],
        "y": ["y", "ý", "ÿ"],
        "c": ["c", "ç", "ć", "č"],
        "n": ["n", "ñ", "ń"],
        "s": ["s", "ß", "ś", "š"],
        "z": ["z", "ź", "ž", "ż"],
        "g": ["g", "ğ"],
        "l": ["l", "ł"],
        "r": ["r", "ř"],
        "t": ["t", "ť"],
        "d": ["d", "đ"],
    ]

    /// Cache so the layout pass (fired often) can skip re-styling every key when
    /// nothing about the appearance actually changed.
    private var cachedIsDarkMode: Bool?
    
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
        // Re-prime immediately so the Taptic Engine is ready for the next tap —
        // without this, consecutive fast taps after the first can feel delayed.
        feedbackGenerator?.prepare()
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        KBLog.lifecycle.log("KeyboardViewController viewDidLoad: begin")

        feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        feedbackGenerator?.prepare()

        // Record Full Access status for the host app to read (see fullAccessKey
        // doc comment) — this only ever writes `true`, since without access the
        // write itself would silently fail anyway. Off-main: the FIRST access to
        // the shared UserDefaults in this process loads its entire plist
        // synchronously, and on a device that hasn't run the legacy-blob
        // migration yet that plist can still be megabytes.
        if hasFullAccess {
            DispatchQueue.global(qos: .utility).async {
                UserDefaults(suiteName: Self.appGroupID)?.set(true, forKey: Self.fullAccessKey)
            }
        }

        setupKeyboardView()
        KBLog.lifecycle.log("KeyboardViewController viewDidLoad: setup complete")

        // First-run explainer — dispatched async, after the keyboard's own
        // UI has been built above, so it never delays first-frame render
        // (see the documented multi-second startup-freeze incident this
        // extension's storage rewrite fixed).
        DispatchQueue.main.async { [weak self] in
            self?.showTutorialOverlayIfNeeded()
        }
    }

    private func showTutorialOverlayIfNeeded() {
        let dismissed = UserDefaults(suiteName: Self.appGroupID)?.bool(forKey: Self.tutorialDismissedKey) ?? false
        guard !dismissed else { return }
        let overlay = KeyboardTutorialOverlay { [weak self] dontShowAgain in
            if dontShowAgain {
                UserDefaults(suiteName: Self.appGroupID)?.set(true, forKey: Self.tutorialDismissedKey)
            }
            self?.tutorialOverlayView?.removeFromSuperview()
            self?.tutorialOverlayView = nil
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        tutorialOverlayView = overlay
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // viewWillLayoutSubviews fires on every layout pass (which can be
        // frequent). Skip the full re-style of every key when appearance hasn't
        // actually changed since last time.
        if cachedIsDarkMode != isDarkMode {
            updateColors()
        }
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
        // This fires after every single keystroke, so — same as
        // viewWillLayoutSubviews — skip the full key re-style when appearance
        // hasn't actually changed.
        if cachedIsDarkMode != isDarkMode {
            updateColors()
        }
        updateShiftStateAfterTextChange()
        updateSuggestions()
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }
    
    // MARK: - Setup
    private func setupKeyboardView() {
        // Set a fixed height for the keyboard to ensure all elements are visible
        // Including hash bar at the bottom (36pt) plus safe area
        let keyboardHeight: CGFloat = 320
        
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

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        suggestionsView.addSubview(stackView)

        // Three reusable slots, populated live by updateSuggestions() from
        // on-device UITextChecker completions/corrections — not static filler.
        suggestionButtons = (0..<3).map { _ in
            let button = UIButton(type: .system)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.isHidden = true
            button.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
            return button
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
        bottomStack.tag = 999  // Tag to identify the bottom row for hash bar constraints
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
        returnKey.backgroundColor = UIColor.systemOrange
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
        // Remove existing hash bar if any
        hashBarView?.removeFromSuperview()
        
        let hashBar = UIView()
        hashBar.translatesAutoresizingMaskIntoConstraints = false
        hashBar.backgroundColor = .clear  // Ensure the bar itself is visible
        keyboardView.addSubview(hashBar)
        hashBarView = hashBar
        
        // Check icon on the left
        let checkIcon = KeyButton()
        checkIcon.keyType = .check
        checkIcon.setImage(UIImage(systemName: "checkmark"), for: .normal)
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        checkIcon.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        checkIcon.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        checkIcon.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        hashBar.addSubview(checkIcon)
        keyButtons.append(checkIcon)
        
        // Hash label
        hashLabel = UILabel()
        hashLabel.text = "#0x000...000"
        hashLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        hashLabel.textAlignment = .center
        hashLabel.translatesAutoresizingMaskIntoConstraints = false
        hashBar.addSubview(hashLabel)
        
        // Proof-link button: sends the drafted message, then a second message
        // with the shareable link to its on-chain proof.
        let copyButton = KeyButton()
        copyButton.keyType = .proofLink
        copyButton.setImage(UIImage(systemName: "link"), for: .normal)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        copyButton.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        hashBar.addSubview(copyButton)
        keyButtons.append(copyButton)
        
        // Anchor hash bar to bottom of keyboardView always with safe area consideration
        NSLayoutConstraint.activate([
            hashBar.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor),
            hashBar.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor),
            hashBar.bottomAnchor.constraint(equalTo: keyboardView.safeAreaLayoutGuide.bottomAnchor, constant: 0),
            hashBar.heightAnchor.constraint(equalToConstant: 36),
            
            checkIcon.leadingAnchor.constraint(equalTo: hashBar.leadingAnchor, constant: 16),
            checkIcon.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            checkIcon.widthAnchor.constraint(equalToConstant: 36),
            checkIcon.heightAnchor.constraint(equalToConstant: 36),
            
            hashLabel.centerXAnchor.constraint(equalTo: hashBar.centerXAnchor),
            hashLabel.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            
            copyButton.trailingAnchor.constraint(equalTo: hashBar.trailingAnchor, constant: -16),
            copyButton.centerYAnchor.constraint(equalTo: hashBar.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 36),
            copyButton.heightAnchor.constraint(equalToConstant: 36)
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
        // Tracks the finger sliding across an open accent popup (see
        // scheduleLongPress/showAccentPopup). No-ops when no popup is open.
        keyButton.addTarget(self, action: #selector(keyDragged(_:forEvent:)), for: [.touchDragInside, .touchDragOutside])

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
        keyButton.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        
        return keyButton
    }
    
    // MARK: - Key Actions
    @objc private func keyTouchDown(_ sender: KeyButton) {
        sender.animatePress()
        triggerHapticFeedback()

        // Capture the key press location for keystroke logging
        let buttonFrame = sender.convert(sender.bounds, to: keyboardView)
        lastKeyPressLocation = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)

        // Show popup for character keys
        if case .character = sender.keyType {
            sender.showKeyPopup(in: keyboardView, isDarkMode: isDarkMode)
            scheduleLongPress(for: sender)
        }

        // Start delete repeat timer for delete key
        if case .delete = sender.keyType {
            startDeleteTimer()
        }
    }

    @objc private func keyTouchUp(_ sender: KeyButton) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        // Character keys route touchUpOutside/touchCancel here (touchUpInside
        // goes to keyTapped instead — see createCharacterKey). Releasing outside
        // the button is exactly what happens when the finger slid across an open
        // accent popup to pick a variant, so this is where that commits.
        if accentPopupKey === sender {
            commitAccentSelection()
            sender.animateRelease()
            return
        }

        sender.animateRelease()
        sender.removeKeyPopup()

        // Stop delete timer
        if case .delete = sender.keyType {
            stopDeleteTimer()
        }
    }

    /// Arms a timer that opens the accent-variant popup if the character key is
    /// still being held when it fires. Uses the key's existing touch tracking
    /// (touchDown/touchDrag*/touchUp*) rather than a separate gesture recognizer,
    /// so there's no risk of it double-firing alongside normal tap handling —
    /// releasing before the timer fires cancels it and behaves exactly as today.
    private func scheduleLongPress(for key: KeyButton) {
        longPressTimer?.invalidate()
        guard case .character(let char) = key.keyType,
              let variants = accentVariants[char.lowercased()],
              variants.count > 1 else { return }
        longPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDuration, repeats: false) { [weak self, weak key] _ in
            guard let self, let key else { return }
            key.removeKeyPopup()
            self.showAccentPopup(for: key, variants: variants)
        }
    }

    /// Tracks the finger sliding across an open accent popup and highlights
    /// whichever variant is currently under it.
    @objc private func keyDragged(_ sender: KeyButton, forEvent event: UIEvent) {
        guard accentPopupKey === sender,
              let touch = event.allTouches?.first else { return }
        updateAccentPopupSelection(location: touch.location(in: keyboardView))
    }
    
    // MARK: - Delete Key Repeat
    private func startDeleteTimer() {
        // Stop any existing timer
        stopDeleteTimer()
        deleteHoldStartTime = Date()

        // Start with initial delay before repeating
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.startFastDeleteTimer()
        }
    }

    private func startFastDeleteTimer() {
        // Rapid single-character deletion. deleteBackward() triggers
        // textDidChange, which already calls updateSuggestions() — no need to
        // call it again here.
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.textDocumentProxy.deleteBackward()
            self.logKeystroke(key: "delete")
            self.triggerHapticFeedback()
            self.updateHashDisplay()
            // Escalate to whole-word deletion after a long hold, like iOS/SwiftKey.
            if let start = self.deleteHoldStartTime,
               Date().timeIntervalSince(start) > Self.deleteWordAccelerationDelay {
                self.startWordDeleteTimer()
            }
        }
    }

    private func startWordDeleteTimer() {
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.deleteWordBackward()
            self.triggerHapticFeedback()
            self.updateHashDisplay()
        }
    }

    /// Deletes back through the current word and any trailing whitespace before
    /// it, in one go. Logs one "delete" keystroke per character actually removed
    /// (not one per word-chunk) so the attested typedText — which replays the
    /// log one character at a time — still matches what's really on screen.
    /// Consecutive deletes logged this way are excluded from the "too fast"
    /// timing penalty in evaluateHumanTyping, since a burst of near-simultaneous
    /// deletes is expected here, not evidence of non-human typing.
    private func deleteWordBackward() {
        guard let context = textDocumentProxy.documentContextBeforeInput, !context.isEmpty else {
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")
            return
        }
        var chars = Array(context)
        var charsToDelete = 0
        while let last = chars.last, last.isWhitespace {
            chars.removeLast(); charsToDelete += 1
        }
        while let last = chars.last, !last.isWhitespace {
            chars.removeLast(); charsToDelete += 1
        }
        for _ in 0..<max(charsToDelete, 1) {
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")
        }
    }

    private func stopDeleteTimer() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteHoldStartTime = nil
    }
    
    @objc private func keyTapped(_ sender: KeyButton) {
        // This is the common path for a character key (touchUpInside only goes
        // here, not to keyTouchUp — see createCharacterKey), so a normal quick
        // tap must cancel the pending long-press timer itself; otherwise it
        // would still fire ~0.35s later and pop up an accent strip for a key
        // that's already been released and handled.
        longPressTimer?.invalidate()
        longPressTimer = nil

        // Character keys route touchUpInside only here (see createCharacterKey),
        // so this is where an accent popup resolved by a plain tap (no drag)
        // commits.
        if accentPopupKey === sender {
            commitAccentSelection()
            sender.animateRelease()
            return
        }

        sender.animateRelease()
        sender.removeKeyPopup()

        // The autocorrect "revert" bubble is only valid for the single tap
        // right after the correction; anything else moves past it.
        if case .space = sender.keyType {} else {
            lastAutocorrect = nil
        }

        // "Return to letters after space" is armed by a qualifying punctuation
        // character and consumed by the very next space (below). Any other key
        // in between invalidates it — e.g. typing "3.14" shouldn't return to
        // letters just because a "1" came after the ".".
        switch sender.keyType {
        case .space, .character: break
        default:
            pendingReturnToLettersAfterSpace = false
            pendingCapitalizeAfterReturn = false
        }

        switch sender.keyType {
        case .character(let char):
            let textToInsert: String
            if shiftState != .off {
                textToInsert = char.uppercased()
            } else {
                textToInsert = char
            }
            textDocumentProxy.insertText(textToInsert)

            // Log the keystroke
            logKeystroke(key: textToInsert)

            // Typing a sentence/clause-ending mark from the numbers/symbols pad
            // arms an auto-return to letters (with capitalization for true
            // sentence-enders) on the next space; anything else typed here
            // instead cancels it.
            if currentMode != .letters, Self.autoReturnToLettersPunctuation.contains(char) {
                pendingReturnToLettersAfterSpace = true
                pendingCapitalizeAfterReturn = Self.autoCapitalizePunctuation.contains(char)
            } else {
                pendingReturnToLettersAfterSpace = false
                pendingCapitalizeAfterReturn = false
            }

            // Auto-disable shift after typing (unless caps lock)
            if shiftState == .on {
                shiftState = .off
                updateShiftKeyAppearance()
            }

        case .shift:
            handleShiftTap()
            logKeystroke(key: "shift")

        case .delete:
            stopDeleteTimer()
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")

        case .numbers:
            toggleMode()
            // No text changed, so textDidChange won't fire on its own — refresh
            // explicitly (currentMode governs whether the bar shows at all).
            updateSuggestions()

        case .symbols:
            toggleSymbols()
            updateSuggestions()

        case .space:
            handleSpaceTap()
            if pendingReturnToLettersAfterSpace {
                pendingReturnToLettersAfterSpace = false
                let shouldCapitalize = pendingCapitalizeAfterReturn
                pendingCapitalizeAfterReturn = false
                currentMode = .letters
                rebuildKeyboardForMode(.letters)
                if shouldCapitalize {
                    shiftState = .on
                    updateShiftKeyAppearance()
                    updateKeyLabels()
                }
            }

        case .returnKey:
            textDocumentProxy.insertText("\n")
            logKeystroke(key: "return")
            
        case .globe:
            // Handled by handleInputModeList
            break
            
        case .emoji:
            // Show custom emoji picker (no text change — refresh explicitly)
            showEmojiPicker()
            updateSuggestions()

        case .microphone:
            // Microphone functionality - requires additional permissions
            break

        case .letters:
            // Return to letters mode from emoji picker (no text change — refresh
            // explicitly)
            currentMode = .letters
            rebuildKeyboardForMode(.letters)
            updateSuggestions()

        case .check:
            // Finalize keystroke session and update hash display
            finalizeKeystrokeSession()

        case .proofLink:
            // Send the drafted message, then a second message with its proof link
            sendProofLink()
        }

        // Cheap: reads a local Int, no IPC/dictionary work. Suggestions refresh
        // via textDidChange for every case that actually mutates text (character/
        // delete/space/return/suggestion-tap/autocorrect all funnel through
        // insertText/deleteBackward, which triggers it automatically) — doing it
        // again here for every key was doubling the per-keystroke cost.
        updateHashDisplay()
    }
    
    // MARK: - Keystroke Logging

    /// Main-thread mirror of the session's keystroke count. logKeystroke() is
    /// always called synchronously on the same thread as every key tap, so this
    /// stays exactly in sync with the logger — without it, showing the live count
    /// after every key required a blocking `workQueue.sync` read on the main
    /// thread, which is unnecessary latency on the single hottest path in the
    /// keyboard (every keystroke).
    private var localKeystrokeCount = 0

    /// Temporary: persisted debug trail readable directly from the shared App
    /// Group storage (no device log tooling needed) — remove once the
    /// "keystroke logs never save" issue is confirmed fixed.
    private func debugCheckpoint(_ label: String) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        var trail = defaults.stringArray(forKey: "debug.checkpoints") ?? []
        trail.append("\(Date()): [VC] \(label)")
        if trail.count > 40 { trail = Array(trail.suffix(40)) }
        defaults.set(trail, forKey: "debug.checkpoints")
        defaults.synchronize()
    }

    private func logKeystroke(key: String) {
        keystrokeLogger.recordKeystroke(
            key: key,
            xCoordinate: Double(lastKeyPressLocation.x),
            yCoordinate: Double(lastKeyPressLocation.y)
        )
        localKeystrokeCount += 1
    }

    private func finalizeKeystrokeSession() {
        debugCheckpoint("Check tapped: localKeystrokeCount = \(localKeystrokeCount)")
        guard localKeystrokeCount > 0 else {
            // No keystrokes to finalize
            return
        }

        // Without Full Access, iOS denies this extension write access to the
        // shared App Group container — per Apple's own docs, "when the user
        // denies Open Access, the extension no longer has write access to the
        // shared group." finalizeCurrentSession() would still return a session
        // (hashing/proof generation don't need the container), so without this
        // check we'd clear currentSession and show "Queued for attestation" for
        // a session that was never actually persisted, silently losing it. Bail
        // out here instead, before the session is discarded, so it's still
        // sitting in the logger ready to save once access is granted.
        guard hasFullAccess else {
            // Same tap feedback as the success path (haptic + color flash) —
            // otherwise this branch is silent enough that a tap here reads as
            // the check button simply not responding, when it's actually
            // blocking on a real precondition the user can fix in Settings.
            hashLabel?.text = "Enable Full Access to save logs"
            let originalColor = hashLabel?.textColor
            hashLabel?.textColor = .systemRed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.hashLabel?.textColor = originalColor
            }
            triggerHapticFeedback()
            return
        }

        if let session = keystrokeLogger.finalizeCurrentSession() {
            localKeystrokeCount = 0
            // Update hash label with finalized session hash
            hashLabel?.text = session.shortHash

            // Visual feedback
            let originalColor = hashLabel?.textColor
            hashLabel?.textColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.hashLabel?.textColor = originalColor
            }

            triggerHapticFeedback()

            // Start attestation right here on the keyboard: prove + submit to the
            // Sur Chain. Proving is ~0.1s; the saved session remains a fallback if
            // the extension is suspended before it completes.
            attestFinalizedSession(session)
        }
    }

    /// Mark a finalized session as requested for attestation. The keyboard
    /// extension can't safely run the ZK prover + chain client (that whole stack,
    /// incl. the Go prover framework, isn't loaded in the extension and would risk
    /// the keyboard's memory limit), so the session — already saved to the shared
    /// app group — is flagged here, and the host app proves + submits it on next
    /// open. Gives the user immediate feedback that attestation has started.
    private func attestFinalizedSession(_ session: KBKeystrokeSession) {
        let count = session.signedKeystrokes.count
        guard count >= 10 else {
            hashLabel?.text = "Too short to attest (≥10)"
            return
        }
        // Record the request so the app surfaces "pending" and attests on launch.
        // synchronize() forces an immediate disk flush — see the detailed
        // comment in KeystrokeLogger.saveSession(): iOS can reclaim this
        // extension's process shortly after this function returns, before the
        // normal deferred UserDefaults sync would otherwise happen.
        if let defaults = UserDefaults(suiteName: Self.appGroupID) {
            var pending = Set(defaults.stringArray(forKey: Self.pendingAttestKey) ?? [])
            pending.insert(session.sessionId)
            defaults.set(Array(pending), forKey: Self.pendingAttestKey)
            defaults.synchronize()
        }
        hashLabel?.text = "Queued for attestation ✓"
        KBLog.signing.log("session \(session.sessionId, privacy: .public) queued for attestation (\(count) keystrokes)")
    }
    
    private func updateHashDisplay() {
        // Show only the live keystroke COUNT here — cheap, and read from the
        // main-thread-local counter (not the logger's queue) so this never blocks
        // on background hashing work. The real hash is shown on finalize and
        // computed on demand when copying.
        if localKeystrokeCount > 0 {
            hashLabel?.text = "\(localKeystrokeCount) keystroke\(localKeystrokeCount == 1 ? "" : "s") logged"
        }
    }
    
    // MARK: - Proof Link

    /// Base URL of the public verifier. The content hash goes in `p`; the
    /// device id (optional, user-controlled, see settings toggle) goes in `d`.
    /// Two distinct paths, not just query params: the website statically
    /// pre-renders a different link-preview card per path (dark when a
    /// device id is included, light when it's a content-only check) — social
    /// crawlers fetch raw HTML and can't branch on query strings, so which
    /// card shows up has to be decided by the path alone.
    private static let verifierBaseURLWithoutDevice = "https://surprotocol.org/v"
    private static let verifierBaseURLWithDevice = "https://surprotocol.org/vd"
    /// App-group flag set by the main app's settings screen: append `&d=<id>`
    /// to shared proof links so the link asserts WHICH device typed it.
    private static let includeDeviceIDKey = "sur.share.includeDeviceIDInLinks"
    /// The registered device id, written by the main app (SurChainIdentityManager).
    private static let deviceIDKey = "sur.identity.username.v1"

    /// Builds the shareable proof link for a content hash, honoring the
    /// "include device id" setting from the main app.
    private func proofLink(forContentHash contentHash: String) -> String {
        if let defaults = UserDefaults(suiteName: Self.appGroupID),
           defaults.bool(forKey: Self.includeDeviceIDKey),
           let deviceID = defaults.string(forKey: Self.deviceIDKey), !deviceID.isEmpty {
            return "\(Self.verifierBaseURLWithDevice)?p=\(contentHash)&d=\(deviceID)"
        }
        return "\(Self.verifierBaseURLWithoutDevice)?p=\(contentHash)"
    }

    /// Sends the drafted message, then a second message containing the link to
    /// its on-chain proof. If a session is in progress it is finalized and
    /// queued for attestation first (same path as the check button), so the
    /// link points at the exact content that was just sent.
    private func sendProofLink() {
        var contentHash: String?

        if localKeystrokeCount > 0 {
            // Same Full Access precondition as the check button: without write
            // access to the app group the session can't be persisted/attested,
            // and a link to a proof that will never exist helps nobody.
            guard hasFullAccess else {
                hashLabel?.text = "Enable Full Access to share proofs"
                let originalColor = hashLabel?.textColor
                hashLabel?.textColor = .systemRed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.hashLabel?.textColor = originalColor
                }
                triggerHapticFeedback()
                return
            }
            if let session = keystrokeLogger.finalizeCurrentSession() {
                localKeystrokeCount = 0
                contentHash = session.contentHash
                attestFinalizedSession(session)
            }
        } else {
            contentHash = keystrokeLogger.lastFinalizedSessionContentHash
        }

        guard let hash = contentHash else {
            hashLabel?.text = "Type something first"
            triggerHapticFeedback()
            return
        }

        let link = proofLink(forContentHash: hash)
        triggerHapticFeedback()

        // 1. Send the drafted message: a newline triggers send in apps whose
        //    return key is "Send" (Messages, WhatsApp, …). 2. After a beat for
        //    the host app to clear its field, insert a clear visual break —
        //    two blank lines plus a short rule — then the link, so the proof
        //    reads as distinctly separate from the message even in apps where
        //    return is just a literal newline (Notes, Mail, a plain text
        //    field, …) rather than "send" (there, everything lands in one
        //    continuous block of text with no bubble boundary to lean on).
        //    3. Send the link as its own message. None of this goes through
        //    logKeystroke — it's generated, not typed, and must not pollute
        //    the next session's keystroke log.
        textDocumentProxy.insertText("\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.textDocumentProxy.insertText("\n\n--------\n\(link)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.textDocumentProxy.insertText("\n")
                self?.hashLabel?.text = "Proof link sent ✓"
            }
        }
    }
    
    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let title = sender.titleLabel?.text else { return }
        let isQuoted = title.hasPrefix("\"") && title.hasSuffix("\"") && title.count >= 2
        let cleanText = isQuoted ? String(title.dropFirst().dropLast()) : title

        // Tapping the quoted "as typed" bubble right after an autocorrect
        // reverts it, rather than being treated as completing the (empty) word
        // that comes after the space which already followed the correction.
        if let revert = lastAutocorrect, cleanText == revert.typed {
            let toRemove = revert.corrected.count + 1 // + the space after it
            for _ in 0..<toRemove {
                textDocumentProxy.deleteBackward()
                logKeystroke(key: "delete")
            }
            textDocumentProxy.insertText(revert.typed + " ")
            logKeystroke(key: revert.typed)
            logKeystroke(key: "space")
            lastAutocorrect = nil
            triggerHapticFeedback()
            updateHashDisplay()
            return
        }

        // Otherwise: replace the word currently being typed with the tapped
        // suggestion. Each deletion/insertion is logged so the attested text
        // matches what actually ends up on screen.
        let originalWord = currentTypedWord()
        for _ in 0..<originalWord.count {
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")
        }
        let matched = matchCase(of: originalWord, to: cleanText)
        textDocumentProxy.insertText(matched + " ")
        logKeystroke(key: matched)
        logKeystroke(key: "space")

        lastAutocorrect = nil
        triggerHapticFeedback()
        updateHashDisplay()
    }

    // MARK: - Predictive Text & Autocorrect
    //
    // Entirely on-device via UITextChecker (Apple's built-in spell-checker) —
    // no network calls, no Full Access entitlement needed, consistent with the
    // rest of this extension's minimal-footprint design.

    /// The word currently being typed: everything after the last whitespace/
    /// newline before the cursor. Derived from the real document context each
    /// time (rather than hand-tracked) so it can never drift out of sync with
    /// what's actually on screen.
    private func currentTypedWord() -> String {
        guard let context = textDocumentProxy.documentContextBeforeInput else { return "" }
        var chars: [Character] = []
        for ch in context.reversed() {
            if ch.isWhitespace || ch.isNewline { break }
            chars.append(ch)
        }
        return String(chars.reversed())
    }

    /// Applies the original word's capitalization pattern to a replacement —
    /// e.g. "Helllo" corrected to "hello" becomes "Hello"; "HELLO" stays
    /// "HELLO".
    private func matchCase(of original: String, to replacement: String) -> String {
        if original.count > 1 && original == original.uppercased() {
            return replacement.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Live, per-keystroke suggestions. Deliberately uses ONLY the cheap
    /// completions() prefix lookup — NOT rangeOfMisspelledWord()/guesses().
    /// guesses() runs a real spell-correction search and is genuinely slow
    /// (tens of ms); calling it here previously blocked the main thread on
    /// nearly every keystroke, because almost every partial word-in-progress
    /// ("k", "ke", "key" while typing "keyboard") registers as "misspelled"
    /// until it's actually finished. That main-thread stall is what was
    /// dropping keystrokes during fast typing — the run loop was busy
    /// spell-checking an unfinished word instead of handling the next touch.
    /// guesses() is still used, appropriately, once per completed word in
    /// performAutocorrectIfNeeded().
    private func updateSuggestions() {
        guard currentMode == .letters, KeyboardSettings.shared.isPredictiveTextEnabled else {
            setSuggestions([])
            return
        }

        var slots: [String] = []
        if let revert = lastAutocorrect {
            slots.append("\"\(revert.typed)\"")
        }

        let word = currentTypedWord()
        if !word.isEmpty {
            let range = NSRange(location: 0, length: word.utf16.count)
            let completions = textChecker.completions(forPartialWordRange: range, in: word, language: "en_US") ?? []

            var seen = Set(slots.map { $0.lowercased() })
            for candidate in completions {
                let key = candidate.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                slots.append(candidate)
                if slots.count >= 3 { break }
            }
            if slots.count < 3 && !seen.contains(word.lowercased()) {
                slots.append("\"\(word)\"")
            }
        }

        setSuggestions(Array(slots.prefix(3)))
    }

    private func setSuggestions(_ suggestions: [String]) {
        for (index, button) in suggestionButtons.enumerated() {
            if index < suggestions.count {
                button.setTitle(suggestions[index], for: .normal)
                button.isHidden = false
            } else {
                button.setTitle(nil, for: .normal)
                button.isHidden = true
            }
        }
    }

    /// If the word just finished looks misspelled and autocorrect is enabled,
    /// silently replaces it with UITextChecker's top guess — preserving the
    /// original capitalization — and remembers it so the "as typed" bubble can
    /// revert it. Each deletion/insertion is logged individually (not as one
    /// aggregate event) so the attested text stays byte-accurate to what's on
    /// screen; the resulting near-simultaneous "delete" timestamps are excluded
    /// from the humanTypingScore's "too fast" penalty (see evaluateHumanTyping)
    /// since this is a legitimate bulk correction, not fabricated typing rhythm.
    private func performAutocorrectIfNeeded() {
        // Disabled for now — pulled out of Keyboard Settings while it's
        // unstable. Re-enable by restoring `KeyboardSettings.shared
        // .isAutocorrectEnabled` here and the "Autocorrect" toggle in
        // AccountView.swift's KeyboardSettingsView once it's solid again.
        guard currentMode == .letters, false else { return }
        let word = currentTypedWord()
        guard word.count >= 2 else { return }

        let range = NSRange(location: 0, length: word.utf16.count)
        let misspelledRange = textChecker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: "en_US"
        )
        guard misspelledRange.location != NSNotFound,
              let guesses = textChecker.guesses(forWordRange: misspelledRange, in: word, language: "en_US"),
              let topGuess = guesses.first,
              topGuess.caseInsensitiveCompare(word) != .orderedSame else { return }

        let corrected = matchCase(of: word, to: topGuess)

        for _ in 0..<word.count {
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")
        }
        textDocumentProxy.insertText(corrected)
        logKeystroke(key: corrected)

        lastAutocorrect = (typed: word, corrected: corrected)
    }

    /// Handles the space key: runs autocorrect on the word just finished (if
    /// enabled), then either inserts a normal space, or — on a quick second tap
    /// — converts the double space into ". " with the next letter
    /// auto-capitalized, matching stock iOS.
    private func handleSpaceTap() {
        performAutocorrectIfNeeded()

        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let now = Date()
        let isDoubleSpaceShortcut = currentMode == .letters
            && KeyboardSettings.shared.isDoubleSpacePeriodEnabled
            && context.hasSuffix(" ")
            && !context.hasSuffix("  ")
            && (lastSpaceTapTime.map { now.timeIntervalSince($0) < 0.3 } ?? false)

        if isDoubleSpaceShortcut {
            textDocumentProxy.deleteBackward()
            logKeystroke(key: "delete")
            textDocumentProxy.insertText(". ")
            logKeystroke(key: ".")
            logKeystroke(key: "space")
            shiftState = .on
            updateShiftKeyAppearance()
            updateKeyLabels()
            lastSpaceTapTime = nil
        } else {
            textDocumentProxy.insertText(" ")
            logKeystroke(key: "space")
            lastSpaceTapTime = now
        }
    }

    // MARK: - Accent Popup (long-press for é, è, ê…)

    /// Shows a horizontal strip of accented variants above `key`. The base
    /// character is always first, so a plain tap-and-release with no drag
    /// (handled by keyTapped, since that's what fires for touchUpInside)
    /// commits the same character a normal tap would have.
    private func showAccentPopup(for key: KeyButton, variants: [String]) {
        dismissAccentPopup()
        accentPopupKey = key
        accentPopupSelectedIndex = 0
        triggerHapticFeedback()

        let isShifted = shiftState != .off
        let displayVariants = isShifted ? variants.map { $0.uppercased() } : variants

        let segmentWidth: CGFloat = 40
        let popupHeight: CGFloat = 48
        let totalWidth = segmentWidth * CGFloat(variants.count)

        let container = UIView()
        container.backgroundColor = isDarkMode ? UIColor(white: 0.25, alpha: 1.0) : .white
        container.layer.cornerRadius = 10
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.layer.shadowOpacity = 0.3
        container.layer.shadowRadius = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(container)

        let buttonFrame = key.convert(key.bounds, to: keyboardView)
        let keyboardWidth = max(keyboardView.bounds.width, totalWidth)
        let halfWidth = totalWidth / 2
        let clampedMidX = min(max(buttonFrame.midX, halfWidth + 4), keyboardWidth - halfWidth - 4)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: totalWidth),
            container.heightAnchor.constraint(equalToConstant: popupHeight),
            container.centerXAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: clampedMidX),
            container.bottomAnchor.constraint(equalTo: keyboardView.topAnchor, constant: buttonFrame.minY - 4)
        ])
        accentPopupView = container
        keyboardView.layoutIfNeeded()

        var segments: [(frame: CGRect, char: String)] = []
        let containerOrigin = container.frame.origin
        for (index, variant) in displayVariants.enumerated() {
            let label = UILabel(frame: CGRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: popupHeight))
            label.text = variant
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 22)
            label.tag = index
            container.addSubview(label)
            segments.append((
                frame: CGRect(x: containerOrigin.x + label.frame.minX, y: containerOrigin.y, width: segmentWidth, height: popupHeight),
                char: variants[index]
            ))
        }
        accentPopupSegments = segments
        styleAccentPopupSelection()
    }

    private func styleAccentPopupSelection() {
        guard let container = accentPopupView else { return }
        for case let label as UILabel in container.subviews {
            let selected = label.tag == accentPopupSelectedIndex
            label.backgroundColor = selected ? .systemOrange : .clear
            label.textColor = selected ? .white : (isDarkMode ? .white : .black)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
        }
    }

    private func updateAccentPopupSelection(location: CGPoint) {
        guard !accentPopupSegments.isEmpty else { return }
        var closestIndex = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for (index, segment) in accentPopupSegments.enumerated() {
            let distance = abs(location.x - segment.frame.midX)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }
        if closestIndex != accentPopupSelectedIndex {
            accentPopupSelectedIndex = closestIndex
            styleAccentPopupSelection()
            triggerHapticFeedback()
        }
    }

    private func commitAccentSelection() {
        defer { dismissAccentPopup() }
        guard accentPopupSegments.indices.contains(accentPopupSelectedIndex) else { return }

        var char = accentPopupSegments[accentPopupSelectedIndex].char
        if shiftState != .off {
            char = char.uppercased()
        }
        textDocumentProxy.insertText(char)
        logKeystroke(key: char)
        if shiftState == .on {
            shiftState = .off
            updateShiftKeyAppearance()
        }
        updateHashDisplay()
    }

    private func dismissAccentPopup() {
        accentPopupView?.removeFromSuperview()
        accentPopupView = nil
        accentPopupKey = nil
        accentPopupSegments = []
        accentPopupSelectedIndex = 0
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
        
        // Log the emoji keystroke
        let buttonFrame = sender.convert(sender.bounds, to: keyboardView)
        lastKeyPressLocation = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        logKeystroke(key: emoji)
        updateHashDisplay()
        
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
        let now = Date()
        // A quick second tap while shift is already on engages caps lock (matches
        // stock iOS); a slower second tap just toggles shift back off.
        let isQuickSecondTap = lastShiftTapTime.map { now.timeIntervalSince($0) < 0.4 } ?? false
        switch shiftState {
        case .off:
            shiftState = .on
        case .on:
            shiftState = isQuickSecondTap ? .capsLock : .off
        case .capsLock:
            shiftState = .off
        }
        lastShiftTapTime = now
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
        // Discard any in-flight long-press/accent-popup state — the buttons it
        // references are about to be torn down.
        longPressTimer?.invalidate()
        longPressTimer = nil
        dismissAccentPopup()

        // Each key's press-popup lives in keyboardView (a sibling, not a
        // subview, of the button) so it can float above the row — it must be
        // torn down explicitly here, or it would be orphaned once these
        // buttons are discarded below.
        for button in keyButtons {
            button.discardKeyPopup()
        }

        // Remove existing key rows
        for stackView in rowStackViews {
            stackView.removeFromSuperview()
        }
        rowStackViews.removeAll()
        keyButtons.removeAll()

        // Remove hash bar (will be recreated)
        hashBarView?.removeFromSuperview()
        hashBarView = nil
        
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
        
        // Always rebuild the hash bar LAST so it's on top
        setupHashBar()
        
        // Bring hash bar to front to ensure visibility
        if let hashBar = hashBarView {
            keyboardView.bringSubviewToFront(hashBar)
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
        bottomStack.tag = 999  // Tag to identify the bottom row for hash bar constraints
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
        returnKey.backgroundColor = UIColor.systemOrange
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
        cachedIsDarkMode = isDarkMode
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
                button.backgroundColor = UIColor.systemOrange
                button.tintColor = .white
            case .globe, .emoji, .microphone, .check, .proofLink:
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
