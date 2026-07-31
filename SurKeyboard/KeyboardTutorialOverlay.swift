//
//  KeyboardTutorialOverlay.swift
//  SurKeyboard
//
//  First-run explainer shown the first time the keyboard opens: what the
//  check button and proof-link button do. UIKit (not SwiftUI) to match the
//  rest of this hand-rolled keyboard UI and avoid SwiftUI-in-extension
//  memory/lifecycle risk. Deliberately lightweight — no images, no
//  animation — given the documented multi-second startup-freeze incident
//  this extension already had from heavy synchronous work on launch.
//

import UIKit

final class KeyboardTutorialOverlay: UIView {
    private let onDismiss: (_ dontShowAgain: Bool) -> Void
    private var isChecked = false
    private let checkboxButton = UIButton(type: .system)

    init(onDismiss: @escaping (_ dontShowAgain: Bool) -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let title = UILabel()
        title.text = "Sur Keyboard"
        title.font = .boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = UILabel()
        body.text = "Tap ✓ to save proof of what you typed. Tap the link icon to send your message plus a link to its on-chain proof."
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabel
        body.numberOfLines = 0
        body.translatesAutoresizingMaskIntoConstraints = false

        checkboxButton.setImage(UIImage(systemName: "square"), for: .normal)
        checkboxButton.tintColor = .secondaryLabel
        checkboxButton.addTarget(self, action: #selector(toggleCheckbox), for: .touchUpInside)
        checkboxButton.translatesAutoresizingMaskIntoConstraints = false

        let checkboxLabel = UILabel()
        checkboxLabel.text = "Don't show this again"
        checkboxLabel.font = .systemFont(ofSize: 12)
        checkboxLabel.textColor = .secondaryLabel
        checkboxLabel.translatesAutoresizingMaskIntoConstraints = false

        let checkboxRow = UIStackView(arrangedSubviews: [checkboxButton, checkboxLabel])
        checkboxRow.axis = .horizontal
        checkboxRow.spacing = 6
        checkboxRow.alignment = .center
        checkboxRow.translatesAutoresizingMaskIntoConstraints = false
        // Tapping the label toggles the checkbox too, not just the tiny glyph.
        let checkboxTap = UITapGestureRecognizer(target: self, action: #selector(toggleCheckbox))
        checkboxRow.addGestureRecognizer(checkboxTap)

        let gotItButton = UIButton(type: .system)
        gotItButton.setTitle("Got it", for: .normal)
        gotItButton.titleLabel?.font = .boldSystemFont(ofSize: 14)
        gotItButton.backgroundColor = .systemOrange
        gotItButton.setTitleColor(.white, for: .normal)
        gotItButton.layer.cornerRadius = 8
        gotItButton.addTarget(self, action: #selector(gotItTapped), for: .touchUpInside)
        gotItButton.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(title)
        card.addSubview(body)
        card.addSubview(checkboxRow)
        card.addSubview(gotItButton)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            checkboxRow.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            checkboxRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

            gotItButton.topAnchor.constraint(equalTo: checkboxRow.bottomAnchor, constant: 12),
            gotItButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            gotItButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            gotItButton.heightAnchor.constraint(equalToConstant: 32),
            gotItButton.widthAnchor.constraint(equalToConstant: 84),
        ])
    }

    @objc private func toggleCheckbox() {
        isChecked.toggle()
        checkboxButton.setImage(UIImage(systemName: isChecked ? "checkmark.square.fill" : "square"), for: .normal)
        checkboxButton.tintColor = isChecked ? .systemOrange : .secondaryLabel
    }

    @objc private func gotItTapped() {
        onDismiss(isChecked)
    }
}
