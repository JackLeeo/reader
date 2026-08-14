import Flutter
import UIKit

@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  // UIKit 会通过 Info.plist 的 UISceneStoryboardFile=Main 自动加载 Main.storyboard
  // (里面已经有 FlutterViewController 作为 rootViewController), 并自动建好 window
  // 这里只声明 window 属性, 让系统接管. 如果自己 new 一个空 window 会把 storyboard 的覆盖掉 → 黑屏
  var window: UIWindow?
}
