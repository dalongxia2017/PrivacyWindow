// 校准用：故意造一个约束冲突，看 "Unable to simultaneously satisfy constraints" 会不会出现在 stderr 里。
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
let content = NSView()
window.contentView = content
let a = NSView(); a.translatesAutoresizingMaskIntoConstraints = false
let b = NSView(); b.translatesAutoresizingMaskIntoConstraints = false
content.addSubview(a); content.addSubview(b)
NSLayoutConstraint.activate([
    a.widthAnchor.constraint(equalToConstant: 100), a.widthAnchor.constraint(equalToConstant: 300),
    a.leadingAnchor.constraint(equalTo: content.leadingAnchor), a.topAnchor.constraint(equalTo: content.topAnchor),
])
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.orderFrontRegardless() }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
app.run()
