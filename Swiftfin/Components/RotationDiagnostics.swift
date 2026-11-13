//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging
import os
import UIKit

// TODO: temporary iPhone Duo rotation diagnostics, remove before upstreaming
//       - logs go to the system log (category "DuoRotation") and Settings > Logs
//       - the experimental fix only runs with the "Duo rotation fix (test)" setting on

enum RotationDiagnostics {

    static let fixDefaultsKey = "duoRotationFix"

    private static let systemLogger = os.Logger(subsystem: "org.jellyfin.swiftfin", category: "DuoRotation")
    private static let appLogger = Logging.Logger.swiftfin()

    @MainActor
    private static weak var activeController: UIViewController?

    @MainActor
    private static var isObservingDevice = false

    static var isFixEnabled: Bool {
        UserDefaults.standard.bool(forKey: fixDefaultsKey)
    }

    // MARK: Logging

    /// Logs to the system log and the in-app log.
    static func log(_ message: String) {
        systemLogger.notice("\(message, privacy: .public)")
        appLogger.notice("[DuoRotation] \(message)")
    }

    /// Logs to the system log only, for frequent events.
    static func trace(_ message: String) {
        systemLogger.notice("\(message, privacy: .public)")
    }

    @MainActor
    static func answered(_ controller: UIViewController, _ mask: UIInterfaceOrientationMask, note: String = "") {
        trace("asked \(type(of: controller)) \(tag(controller)) -> \(mask.debugDescription) \(note)")
    }

    @MainActor
    static func maskChanged(_ controller: UIViewController, from oldMask: UIInterfaceOrientationMask, to newMask: UIInterfaceOrientationMask) {
        guard oldMask != newMask else { return }

        log("mask \(tag(controller)) \(oldMask.debugDescription) -> \(newMask.debugDescription) \(describe(controller))")

        if newMask.isDisjoint(with: .landscape), activeController === controller {
            activeController = nil
        }
    }

    @MainActor
    static func didAppear(_ controller: UIViewController, mask: UIInterfaceOrientationMask) {
        startObservingDevice()

        log("appear \(tag(controller)) mask=\(mask.debugDescription) fix=\(isFixEnabled) \(describe(controller))")

        if !mask.isDisjoint(with: .landscape) {
            activeController = controller
            matchDeviceOrientation(controller)
        }
    }

    @MainActor
    static func willDisappear(_ controller: UIViewController) {
        log("disappear \(tag(controller)) \(describe(controller))")

        if activeController === controller {
            activeController = nil
        }
    }

    @MainActor
    static func willTransition(
        _ controller: UIViewController,
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        let controllerTag = tag(controller)

        log("transition \(controllerTag) to \(size) \(describe(controller))")

        coordinator.animate(alongsideTransition: nil) { [weak controller] _ in
            MainActor.assumeIsolated {
                Self.log("transitioned \(controllerTag) \(Self.describe(controller))")
            }
        }
    }

    // MARK: Experimental Fix

    /// Asks the scene to rotate to match the physical device orientation, if the controller allows it.
    @MainActor
    static func matchDeviceOrientation(_ controller: UIViewController) {
        guard isFixEnabled,
              let scene = controller.viewIfLoaded?.window?.windowScene
        else { return }

        let target: UIInterfaceOrientationMask = switch UIDevice.current.orientation {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        case .portrait: .portrait
        default: []
        }

        guard !target.isEmpty,
              controller.supportedInterfaceOrientations.contains(target),
              target != mask(for: scene.effectiveGeometry.interfaceOrientation)
        else { return }

        log("requesting \(target.debugDescription) \(describe(controller))")

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            Self.log("request \(target.debugDescription) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Device

    @MainActor
    private static func startObservingDevice() {
        guard !isObservingDevice else { return }
        isObservingDevice = true

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        _ = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.deviceOrientationDidChange()
            }
        }
    }

    @MainActor
    private static func deviceOrientationDidChange() {
        log("device \(name(UIDevice.current.orientation)) \(describe(activeController))")

        if let activeController {
            matchDeviceOrientation(activeController)
        }
    }

    // MARK: Description

    @MainActor
    private static func describe(_ controller: UIViewController?) -> String {
        guard let scene = controller?.viewIfLoaded?.window?.windowScene else { return "scene=nil" }

        let geometry = scene.effectiveGeometry
        let traits = scene.traitCollection

        return [
            "interface=\(name(geometry.interfaceOrientation))",
            "device=\(name(UIDevice.current.orientation))",
            "scene=\(geometry.coordinateSpace.bounds.size)",
            "screen=\(scene.screen.bounds.size)",
            "mainScreen=\(scene.screen === UIScreen.main)",
            "idiom=\(UIDevice.current.userInterfaceIdiom.rawValue)",
            "sizeClass=\(name(traits.horizontalSizeClass))/\(name(traits.verticalSizeClass))",
        ]
        .joined(separator: " ")
    }

    private static func tag(_ controller: UIViewController) -> String {
        String(describing: Unmanaged.passUnretained(controller).toOpaque())
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
    }

    private static func name(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "upsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }

    private static func name(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "upsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .faceUp: "faceUp"
        case .faceDown: "faceDown"
        default: "unknown"
        }
    }

    private static func name(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }
}
