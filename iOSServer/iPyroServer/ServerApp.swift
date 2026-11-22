import Combine
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

@main
final class PyroWaveAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = PyroWaveSceneDelegate.self
        return configuration
    }
}

final class PyroWaveSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var cancellables = Set<AnyCancellable>()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        let serverModel = IOSServerModel()
        let receiverModel = IOSReceiverModel()

        // LocalSend-inspired 3-tab layout: Receive (Receive Stream), Send (Server), Settings (Gear)
        let receiverVC = IOSReceiverViewController(model: receiverModel, serverModel: serverModel)
        receiverVC.tabBarItem = UITabBarItem(
            title: SPPWLocalization.tr("tab.receiver"),
            image: UIImage(systemName: "dot.radiowaves.left.and.right"),
            selectedImage: UIImage(systemName: "dot.radiowaves.left.and.right.fill")
        )
        let receiverNav = UINavigationController(rootViewController: receiverVC)

        let serverVC = IOSServerViewController(model: serverModel, receiverModel: receiverModel)
        serverVC.tabBarItem = UITabBarItem(
            title: SPPWLocalization.tr("tab.server"),
            image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
            selectedImage: UIImage(systemName: "antenna.radiowaves.left.and.right.fill")
        )
        let serverNav = UINavigationController(rootViewController: serverVC)

        let settingsVC = IOSSettingsViewController(receiverModel: receiverModel, serverModel: serverModel)
        settingsVC.tabBarItem = UITabBarItem(
            title: SPPWLocalization.tr("tab.settings"),
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )
        let settingsNav = UINavigationController(rootViewController: settingsVC)

        let tabController = UITabBarController()
        tabController.viewControllers = [receiverNav, serverNav, settingsNav]
        tabController.tabBar.tintColor = .systemBlue

        NotificationCenter.default.publisher(for: SPPWLocalization.didChangeLanguageNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                receiverVC.tabBarItem.title = SPPWLocalization.tr("tab.receiver")
                serverVC.tabBarItem.title = SPPWLocalization.tr("tab.server")
                settingsVC.tabBarItem.title = SPPWLocalization.tr("tab.settings")
            }
            .store(in: &cancellables)

        window.rootViewController = tabController
        window.makeKeyAndVisible()
        self.window = window
    }
}
