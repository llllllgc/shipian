import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var scopedURLs: [String: URL] = [:]
  private var lifecycle: FlutterMethodChannel?
  private var mayClose = false
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y,
                         width: 1400, height: 900), display: true)
    self.minSize = NSSize(width: 980, height: 760)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let folders = FlutterMethodChannel(name: "shipian/folders", binaryMessenger: flutterViewController.engine.binaryMessenger)
    folders.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: String] else {
        result(FlutterError(code: "arguments", message: "目录参数无效", details: nil)); return
      }
      do {
        switch call.method {
        case "remember":
          guard let path = args["path"] else { throw CocoaError(.fileReadInvalidFileName) }
          let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
          let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
          result(data.base64EncodedString())
        case "restore":
          guard let value = args["bookmark"], let data = Data(base64Encoded: value) else { throw CocoaError(.fileReadCorruptFile) }
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
          if self.scopedURLs[url.path] == nil {
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            self.scopedURLs[url.path] = url
          }
          result(url.path)
        default: result(FlutterMethodNotImplemented)
        }
      } catch { result(FlutterError(code: "folderAccess", message: error.localizedDescription, details: nil)) }
    }
    lifecycle = FlutterMethodChannel(name: "shipian/lifecycle", binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.delegate = self

    super.awakeFromNib()
  }

  func prepareToClose(_ completion: @escaping (Bool) -> Void) {
    guard let lifecycle = lifecycle else { completion(true); return }
    lifecycle.invokeMethod("prepareToClose", arguments: nil) { response in
      if let success = response as? Bool, success {
        completion(true)
      } else {
        let alert = NSAlert()
        alert.messageText = "任务未能保存"
        alert.informativeText = "请检查磁盘后重试。"
        alert.runModal()
        completion(false)
      }
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if mayClose { return true }
    prepareToClose { [weak self] success in
      if success { self?.mayClose = true; self?.performClose(nil) }
    }
    return false
  }

  deinit { scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() } }
}
