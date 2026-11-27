// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// "You have earned a trophy": a banner that drops in at the top of the game, as on a Vita, with the
/// trophy's picture, name and grade. Several in a row queue up.
final class TrophyBannerView: UIView {
    struct Earned {
        let name: String
        let grade: Int
        let icon: UIImage?
    }

    private static var queue: [Earned] = []
    private static weak var showing: TrophyBannerView?

    static func show(_ earned: Earned) {
        queue.append(earned)
        if showing == nil { next() }
    }

    private static func next() {
        guard !queue.isEmpty, let host = ControlsHost.window?.rootViewController?.view else {
            queue.removeAll()
            return
        }
        let banner = TrophyBannerView(queue.removeFirst())
        showing = banner
        banner.present(in: host)
    }

    private init(_ earned: Earned) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.layer.cornerRadius = 22
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        let icon = UIImageView(image: earned.icon ?? UIImage(systemName: "trophy.fill"))
        icon.tintColor = UIColor(TrophyGrade.color(earned.grade))
        icon.contentMode = earned.icon == nil ? .center : .scaleAspectFill
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true
        icon.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let cup = UIImageView(image: UIImage(systemName: "trophy.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        cup.tintColor = UIColor(TrophyGrade.color(earned.grade))
        let caption = UILabel()
        caption.text = L("You have earned a trophy.")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = UIColor.white.withAlphaComponent(0.7)
        let top = UIStackView(arrangedSubviews: [cup, caption])
        top.spacing = 5
        let name = UILabel()
        name.text = earned.name
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        let texts = UIStackView(arrangedSubviews: [top, name])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
        ])
        accessibilityLabel = L("You have earned a trophy.") + " " + earned.name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present(in host: UIView) {
        let width = min(host.bounds.width - 32, 380)
        let top = host.safeAreaInsets.top + 10
        frame = CGRect(x: host.bounds.midX - width / 2, y: top, width: width, height: 60)
        autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        host.addSubview(self)
        transform = CGAffineTransform(translationX: 0, y: -(top + 80))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3) {
            self.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 4.2, options: [.curveEaseIn], animations: {
            self.transform = CGAffineTransform(translationX: 0, y: -(top + 80))
        }, completion: { _ in
            self.removeFromSuperview()
            TrophyBannerView.next()
        })
    }
}

/// Called by SceNpTrophy (on the emulator's thread) as a trophy unlocks
@_cdecl("v3k_trophy_unlocked")
public func v3kTrophyUnlocked(_ name: UnsafePointer<CChar>?, _ detail: UnsafePointer<CChar>?, _ grade: Int32,
                              _ icon: UnsafePointer<UInt8>?, _ iconSize: UInt32) {
    let title = name.map { String(cString: $0) } ?? ""
    let data = icon.map { Data(bytes: $0, count: Int(iconSize)) }
    DispatchQueue.main.async {
        guard UserDefaults.standard.object(forKey: "v3k.trophyBanner") as? Bool ?? true else { return }
        TrophyBannerView.show(.init(name: title, grade: Int(grade), icon: data.flatMap { UIImage(data: $0) }))
    }
}

/// Called by the watchdog when a game has shown no new picture for 25 seconds (stuck on a splash screen,
/// frozen): says so, and how to get the log that shows why to us. The watchdog has just written what
/// every game thread was doing into that log.
@_cdecl("v3k_game_seems_stuck")
public func v3kGameSeemsStuck() {
    DispatchQueue.main.async {
        guard let root = ControlsHost.window?.rootViewController, root.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("This game seems stuck"),
            message: L("Nothing new has been drawn for 25 seconds. If it stays like this, quit, then Settings › About › Report on GitHub: the report says what the game was doing."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Keep waiting"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Quit game"), style: .destructive) { _ in
            v3k_set_game_paused(2, false)
            v3k_set_game_paused(1, false)
            v3k_pad_request_exit()
        })
        root.present(alert, animated: true)
    }
}
