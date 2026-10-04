import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    if isMemoryChild {
      // Measuring only. The window still has to appear once (that starts
      // the Flutter engine), so it appears transparent, click-through and
      // off-screen.
      self.alphaValue = 0
      self.ignoresMouseEvents = true
      self.hasShadow = false
      self.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }
  }

  // A memory child never takes keyboard focus.
  override var canBecomeKey: Bool { isMemoryChild ? false : super.canBecomeKey }
  override var canBecomeMain: Bool { isMemoryChild ? false : super.canBecomeMain }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // Keep a memory child's window off-screen.
    isMemoryChild ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }
}
