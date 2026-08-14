import Flutter
import UIKit

@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // UI 由 Main.storyboard 加载 (FlutterViewController), 这里只接管 window 引用
    guard let windowScene = scene as? UIWindowScene else { return }
    self.window = UIWindow(windowScene: windowScene)
  }
}
