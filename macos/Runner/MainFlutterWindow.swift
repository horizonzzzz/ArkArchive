import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cacheAccess: [String: URL] = [:]

  private func configureCacheDirectoryChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "story_cache_directory", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let path = call.arguments as? String else {
        result(FlutterError(code: "invalid_path", message: "缓存目录无效", details: nil))
        return
      }
      do {
        let key = "story-cache-bookmark:" + path
        switch call.method {
        case "save":
          let url = URL(fileURLWithPath: path, isDirectory: true)
          let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          UserDefaults.standard.set(data, forKey: key)
          if self.cacheAccess[path] == nil && url.startAccessingSecurityScopedResource() { self.cacheAccess[path] = url }
          result(nil)
        case "restore":
          if self.cacheAccess[path] != nil {
            result(nil)
            return
          }
          guard let data = UserDefaults.standard.data(forKey: key) else {
            result(FlutterError(code: "missing_bookmark", message: "缺少缓存目录访问授权", details: nil))
            return
          }
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
          guard url.startAccessingSecurityScopedResource() else {
            result(FlutterError(code: "access_denied", message: "无法访问缓存目录", details: nil))
            return
          }
          self.cacheAccess[path] = url
          if stale {
            let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(refreshed, forKey: key)
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "bookmark_error", message: error.localizedDescription, details: nil))
      }
    }
  }

  deinit {
    for url in cacheAccess.values { url.stopAccessingSecurityScopedResource() }
  }
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureCacheDirectoryChannel(flutterViewController)

    super.awakeFromNib()
  }
}