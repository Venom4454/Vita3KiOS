// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// The game that's running, for the quick menu's header (set when a Vita game launches)
enum VitaSession {
    static var title: String?
    static var iconPath: String?
    static var startedAt: Date?
}

/// The in-game quick menu, PS Vita and 3DS (HOME, or the controller's Home/PS button): a glass card over the paused game
/// with everything the old top row and game menu had, as tiles. Tapping outside, "Back to game" or
/// HOME again closes it.
final class GameQuickMenuView: UIView {
    struct Item {
        let symbol: String
        let title: String
        var active = false
        var destructive = false
        var enabled = true
        let action: () -> Void
    }

    private let backdrop = UIVisualEffectView(effect: nil)
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let header = UIStackView()
    private let grid = UIStackView()
    private let resumeButton = UIButton(type: .system)
    private let onClose: () -> Void
    private var closing = false

    /// paused: the player had paused the game; "Resume game" then runs `resume`
    /// title, iconPath, startedAt: the header (the running Vita game when not given)
    init(items: [Item], paused: Bool, title gameTitle: String? = nil, iconPath: String? = nil, startedAt: Date? = nil,
         detail: String? = nil, resume: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)

        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        addSubview(backdrop)
        let tapOutside = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        backdrop.addGestureRecognizer(tapOutside)

        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        addSubview(card)

        // Header: the game's icon, its name and how long this session has run
        let icon = UIImageView()
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 12
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        if let path = iconPath ?? VitaSession.iconPath, !path.isEmpty { icon.image = UIImage(contentsOfFile: path) }
        icon.isHidden = icon.image == nil
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let title = UILabel()
        title.text = gameTitle ?? VitaSession.title ?? L("Quick menu")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        let subtitle = UILabel()
        var line = detail ?? (paused ? L("Paused") : L("Paused while this menu is open"))
        if let started = startedAt ?? VitaSession.startedAt {
            let minutes = Int(Date().timeIntervalSince(started) / 60)
            if minutes >= 1 { line += " · " + String(format: L("%lld min this session"), minutes) }
        }
        subtitle.text = line
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.6)
        let titles = UIStackView(arrangedSubviews: [title, subtitle])
        titles.axis = .vertical
        titles.spacing = 2
        header.addArrangedSubview(icon)
        header.addArrangedSubview(titles)
        header.spacing = 12
        header.alignment = .center
        card.contentView.addSubview(header)

        // Tiles, four to a row
        grid.axis = .vertical
        grid.spacing = 10
        grid.distribution = .fillEqually
        var row: UIStackView?
        for (index, item) in items.enumerated() {
            if index % 4 == 0 {
                let next = UIStackView()
                next.spacing = 10
                next.distribution = .fillEqually
                grid.addArrangedSubview(next)
                row = next
            }
            row?.addArrangedSubview(tile(item))
        }
        // keep the last row's tiles the same width as the others
        if let row, items.count % 4 != 0 {
            for _ in 0..<(4 - items.count % 4) { row.addArrangedSubview(UIView()) }
        }
        card.contentView.addSubview(grid)

        var config = UIButton.Configuration.filled()
        config.title = paused ? L("Resume game") : L("Back to game")
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accentUIColor
        config.baseForegroundColor = .white
        resumeButton.configuration = config
        resumeButton.addAction(UIAction { [weak self] _ in
            self?.close(then: paused ? resume : nil)
        }, for: .touchUpInside)
        card.contentView.addSubview(resumeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func tile(_ item: Item) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold))
        config.imagePlacement = .top
        config.imagePadding = 7
        var title = AttributedString(item.title)
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        config.attributedTitle = title
        config.titleAlignment = .center
        config.titleLineBreakMode = .byWordWrapping
        let tint: UIColor = item.destructive ? .systemRed : (item.active ? Theme.accentUIColor : .white)
        config.baseForegroundColor = tint
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 4, bottom: 8, trailing: 4)
        let button = UIButton(configuration: config)
        button.backgroundColor = item.active ? Theme.accentUIColor.withAlphaComponent(0.18) : UIColor.white.withAlphaComponent(0.07)
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
        button.accessibilityLabel = item.title
        button.isEnabled = item.enabled
        button.alpha = item.enabled ? 1 : 0.38
        button.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.close(then: item.action)
        }, for: .touchUpInside)
        return button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 16, dy: 12)
        let width = min(safe.width, 540)
        let padding: CGFloat = 20
        let rows = CGFloat(grid.arrangedSubviews.count)
        let tileHeight: CGFloat = min(84, max((safe.height - 44 - 52 - padding * 2 - 36 - rows * 10) / max(rows, 1), 60))
        let gridHeight = rows * tileHeight + max(rows - 1, 0) * 10
        let height = padding + 44 + 16 + gridHeight + 16 + 48 + padding
        card.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let inner = card.bounds.insetBy(dx: padding, dy: padding)
        header.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 44)
        grid.frame = CGRect(x: inner.minX, y: header.frame.maxY + 16, width: inner.width, height: gridHeight)
        resumeButton.frame = CGRect(x: inner.minX, y: grid.frame.maxY + 16, width: inner.width, height: 48)
    }

    func present(in host: UIView) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        layoutIfNeeded()
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 12)
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4) {
            self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            self.card.alpha = 1
            self.card.transform = .identity
        }
    }

    @objc private func closeTapped() { close() }

    /// Closes (the game resumes unless the player paused it), then runs `then`
    func close(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        UIView.animate(withDuration: 0.18, animations: {
            self.backdrop.effect = nil
            self.backdrop.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            self.removeFromSuperview()
            self.onClose()
            action?()
        })
    }
}
