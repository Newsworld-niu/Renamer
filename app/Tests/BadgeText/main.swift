import AppKit

let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
var passed = 0
for name in ["Vscode", "Chatgpt", "Quant", "Music production", "工作和项目管理", "🎵 音乐 Music"] {
    let width = BadgeView.preferredWidth(for: name, font: font)
    let view = BadgeView(frame: .zero)
    view.label.stringValue = name
    view.label.font = font
    view.frame = NSRect(x: 0, y: 0, width: width, height: 24)
    view.layoutSubtreeIfNeeded()
    precondition(view.label.frame.width >= view.label.cell!.cellSize.width, "Truncated at natural width: \(name)")
    passed += 1
    // The actual miniature layout must leave enough space, not just the
    // isolated text measurement. Repeat while its hover geometry grows.
    for step in 0...10 {
        let geometry = ButtonGeometry(frame: CGRect(x: 20, y: 10, width: 210 + step * 2, height: 100 + step), title: nil)
        view.frame = BadgeLayout.frame(geometry: geometry, screen: screen, preferredWidth: width)!
        view.layoutSubtreeIfNeeded()
        precondition(view.label.frame.width >= view.label.cell!.cellSize.width, "Hover truncated: \(name)")
    }
    passed += 1
    view.frame.size.width = width
    view.layoutSubtreeIfNeeded()
    precondition(view.label.frame.width >= view.label.cell!.cellSize.width, "Reverse hover truncated: \(name)")
    passed += 1
}
for size in [11.0, 14.0, 20.0] {
    for name in ["Chatgpt", "Vscode", "工作项目"] {
        let style = BadgeAppearance(fontSize: size)
        let view = BadgeView(frame: .zero)
        view.apply(name: name, appearance: style)
        let width = BadgeView.preferredWidth(for: name, font: view.label.font!)
        view.frame = NSRect(x: 0, y: 0, width: width, height: style.height)
        view.layoutSubtreeIfNeeded()
        precondition(view.label.frame.width >= view.label.cell!.cellSize.width, "Size control truncated text")
        precondition(view.label.frame.height >= view.label.cell!.cellSize.height, "Size control clipped text vertically")
        precondition(view.label.font!.pointSize == size, "Size control not applied")
        passed += 1
    }
}

for size in [16.0, 28, 48, 64] {
    for name in ["Chatgpt", "工作和项目管理", "🎵 Music"] {
        var style = CurrentBadgeAppearance()
        style.fontSize = size
        let view = BadgeView(frame: .zero)
        view.apply(name: name, fontSize: style.fontSize, background: style.background.nsColor, foreground: style.foreground.nsColor)
        let width = BadgeView.preferredWidth(for: name, font: view.label.font!)
        view.frame = NSRect(x: 0, y: 0, width: width, height: style.height)
        view.layoutSubtreeIfNeeded()
        precondition(view.label.frame.width >= view.label.cell!.cellSize.width, "Current label width clips text")
        precondition(view.label.frame.height >= view.label.cell!.cellSize.height, "Current label height clips large text")
        passed += 1
    }
}
var colored = BadgeAppearance()
colored.foreground = BadgeColor(red: 0.9, green: 0.2, blue: 0.1)
let customView = BadgeView(frame: .zero)
customView.apply(name: "Chatgpt", appearance: colored)
precondition(customView.label.textColor == colored.foreground!.nsColor, "Custom thumbnail text color not applied")
passed += 1
print("\(passed) AppKit text-fitting checks passed")
