//
//  OrientationLock.swift
//  ThreeDee
//
//  Lets a screen pin the interface orientation (VR mode holds the phone in
//  landscape inside a headset).
//

import UIKit

enum OrientationLock {
    private static var override: UIInterfaceOrientationMask?

    static var mask: UIInterfaceOrientationMask {
        override ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
    }

    /// Pins the interface to `mask` (nil restores the app's normal orientations) and rotates now if needed.
    static func set(_ mask: UIInterfaceOrientationMask?) {
        guard override != mask else { return }
        override = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            if let mask {
                let current = scene.effectiveGeometry.interfaceOrientation
                let fits = (current.isLandscape && mask.contains(.landscape)) || (current.isPortrait && mask.contains(.portrait))
                if !fits { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask.contains(.landscapeRight) ? .landscapeRight : mask)) }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
