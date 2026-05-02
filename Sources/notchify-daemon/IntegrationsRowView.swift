import AppKit

// Custom NSMenuItem.view used for integration rows that need a
// right-edge attention dot. NSMenuItem's attributedTitle ignores tab
// stops aggressively enough that we can't get a flush-right indicator
// any other way, so this view draws everything itself: leading icon,
// title text, optional trailing chevron (for the rootItem with a
// submenu), and a small red dot pinned to the right edge.
//
// Replicates the standard menu-item highlight behavior by observing
// enclosingMenuItem.isHighlighted via KVO and redrawing the
// background. Without this, hovering the row wouldn't visibly
// highlight the way default menu items do.
@MainActor
final class IntegrationsRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let checkmarkView = NSImageView()
    private let dotView = NSView()
    private let chevronView = NSImageView()
    private let showsChevron: Bool
    private let isDimmed: Bool
    private weak var menuItem: NSMenuItem?
    private var highlightObservation: NSKeyValueObservation?

    init(
        title: String,
        icon: NSImage?,
        showsCheckmark: Bool,
        showsAttentionDot: Bool,
        showsChevron: Bool,
        isDimmed: Bool,
        compactIndent: Bool,
        menuItem: NSMenuItem
    ) {
        self.isDimmed = isDimmed
        self.showsChevron = showsChevron
        self.menuItem = menuItem
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]

        // Reserved leading checkmark slot. Always laid out so titles
        // align across rows; only painted when showsCheckmark.
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmarkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        checkmarkView.contentTintColor = .labelColor
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkView.isHidden = !showsCheckmark
        addSubview(checkmarkView)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        let dotSize: CGFloat = 7
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView.layer?.cornerRadius = dotSize / 2
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.isHidden = !showsAttentionDot
        addSubview(dotView)

        if showsChevron {
            chevronView.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: nil
            )
            chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            chevronView.contentTintColor = .secondaryLabelColor
            chevronView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevronView)
        }

        // Layout columns. Two indent modes:
        //   compactIndent (parent rootItem): title at ~21pt to match
        //     default chrome's text position in a menu that reserves
        //     a checkmark column (so this view aligns with sibling
        //     items rendered the standard way).
        //   regular (recipe rows): full layout with reserved checkmark
        //     and icon columns, title at ~44pt.
        let checkmarkSlot: CGFloat = 14
        let iconColumn: CGFloat = 16
        // NSTextField (even labelStyle) has ~2pt of internal padding
        // before the first glyph, while default menu chrome draws
        // glyphs flush against its computed indent. Subtract that
        // so our text glyphs land at the same x as default-rendered
        // siblings (About, Install CLI, Quit).
        let textFieldInset: CGFloat = 2
        let textIndent: CGFloat = compactIndent
            ? (21 - textFieldInset)
            : (6 + checkmarkSlot + 2 + iconColumn + 6 - textFieldInset)
        var constraints: [NSLayoutConstraint] = [
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6 + checkmarkSlot / 2),

            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconColumn),
            iconView.heightAnchor.constraint(equalToConstant: iconColumn),
            iconView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6 + checkmarkSlot + 2 + iconColumn / 2),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textIndent),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            dotView.widthAnchor.constraint(equalToConstant: dotSize),
            dotView.heightAnchor.constraint(equalToConstant: dotSize),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        iconView.isHidden = (icon == nil)
        if showsChevron {
            constraints += [
                chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
                dotView.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            ]
        } else {
            constraints += [
                dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ]
        }
        // Keep the title from running into the dot.
        let trailingTitle = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: dotView.leadingAnchor, constant: -8
        )
        trailingTitle.priority = .defaultHigh
        constraints.append(trailingTitle)
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // NSMenuItem.view replaces the standard mouse-handling chrome,
    // so clicks on the view don't trigger the item's action by
    // themselves. We dismiss the menu and forward the action manually.
    // Items with a submenu (rootItem) have no action — NSMenu still
    // expands their submenu on hover via its own machinery, which we
    // don't interfere with here.
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem ?? menuItem,
              let action = item.action else {
            super.mouseUp(with: event)
            return
        }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-bind highlight tracking each time the view appears
        // (menus tear down + recreate on each open).
        highlightObservation?.invalidate()
        guard let item = enclosingMenuItem ?? menuItem else { return }
        highlightObservation = item.observe(\.isHighlighted, options: [.initial, .new]) { [weak self] _, _ in
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let item = enclosingMenuItem ?? menuItem
        if item?.isHighlighted == true {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
            titleLabel.textColor = .selectedMenuItemTextColor
            chevronView.contentTintColor = .selectedMenuItemTextColor
        } else {
            titleLabel.textColor = isDimmed ? .secondaryLabelColor : .labelColor
            chevronView.contentTintColor = .secondaryLabelColor
        }
        super.draw(dirtyRect)
    }
}
