//
//  ScreenshotProtected.swift
//  Unspoken
//
// UITextField with isSecureTextEntry=true has a system-level CALayer that is
// excluded from screenshots. Embedding any view inside that layer inherits the
// same protection — content shows normally on screen but appears blank in screenshots.
//

import SwiftUI
import UIKit

// Subclass that never becomes first responder, so it won't intercept taps or
// show a keyboard, while still allowing touches to reach its subviews.
private final class PassthroughTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

class SecureContainerView: UIView {
    private let secureField = PassthroughTextField()
    private weak var embeddedView: UIView?
    weak var hostingController: UIViewController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        secureField.isSecureTextEntry = true
        secureField.backgroundColor = .clear
        addSubview(secureField)
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ view: UIView) {
        embeddedView = view
        guard let secureLayer = secureField.subviews.first else { return }
        secureLayer.addSubview(view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        secureField.frame = bounds
        guard let secureLayer = secureField.subviews.first else { return }
        secureLayer.frame = bounds
        embeddedView?.frame = bounds
    }

    // Properly add UIHostingController as child VC to avoid layout loops.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let hc = hostingController, hc.parent == nil else { return }
        var responder: UIResponder? = next
        while let r = responder {
            if let vc = r as? UIViewController {
                vc.addChild(hc)
                hc.didMove(toParent: vc)
                return
            }
            responder = r.next
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil, let hc = hostingController, hc.parent != nil {
            hc.willMove(toParent: nil)
            hc.removeFromParent()
        }
        super.willMove(toWindow: newWindow)
    }
}

struct ScreenshotProtected<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(content: content()) }

    func makeUIView(context: Context) -> SecureContainerView {
        let container = SecureContainerView()
        container.backgroundColor = .clear
        container.embed(context.coordinator.host.view)
        container.hostingController = context.coordinator.host
        return container
    }

    func updateUIView(_ uiView: SecureContainerView, context: Context) {
        context.coordinator.host.rootView = content()
    }

    class Coordinator {
        let host: UIHostingController<Content>
        init(content: Content) {
            host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
        }
    }
}
