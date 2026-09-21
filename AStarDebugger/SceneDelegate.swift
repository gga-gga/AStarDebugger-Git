//
//  SceneDelegate.swift
//  OGMDebugViewer — Storyboardを使わず、コードでルートViewControllerを構築する
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = OGMDebugViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
