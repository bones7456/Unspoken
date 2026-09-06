//
//  ContentView.swift
//  Unspoken
//

import SwiftUI

// MARK: - ImageGallery

// Every image in the conversation plus which one was tapped, so the full-screen viewer can
// page between them. A snapshot taken at tap time, deliberately not a live view of
// `viewModel.messages`: an image arriving mid-browse would grow the array and shift the index
// out from under the user's finger.
private struct ImageGallery: Identifiable {
    let id = UUID()
    let images: [Data]      // oldest first, matching the message order
    let startIndex: Int
}

// Batch of images awaiting send confirmation, in the order the user picked them.
private struct IdentifiableImages: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

// MARK: - ActiveSheet
// Single source of truth for every sheet on ContentView. Stacking multiple `.sheet`
// modifiers on one view orphans the later presentation contexts — a sheet presented
// from a third/fourth modifier gets torn down when an earlier presenter (e.g. the
// confirmation dialog) finishes dismissing. Same lesson the alerts already learned.
private enum ActiveSheet: Identifiable {
    case imagePicker
    case memeSearch
    case confirmImage(IdentifiableImages)
    case fullScreenImage(ImageGallery)

    var id: String {
        switch self {
        case .imagePicker:              return "imagePicker"
        case .memeSearch:               return "memeSearch"
        case .confirmImage(let i):      return "confirm-\(i.id)"
        case .fullScreenImage(let g):   return "full-\(g.id)"
        }
    }
}

// MARK: - ImageGalleryView
// Full-screen image viewer: swipe between every image in the conversation, pinch or
// double-tap to zoom. Stays inside ScreenshotProtected — the whole point of the app.

private struct ImageGalleryView: View {
    let gallery: ImageGallery
    let onClose: () -> Void

    @State private var index: Int
    // Tracks only the page on screen, so a zoomed-then-swiped-away page can't leave this stuck.
    @State private var isZoomed: Bool = false

    init(gallery: ImageGallery, onClose: @escaping () -> Void) {
        self.gallery = gallery
        self.onClose = onClose
        _index = State(initialValue: gallery.startIndex)
    }

    var body: some View {
        ScreenshotProtected {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                TabView(selection: $index) {
                    ForEach(gallery.images.indices, id: \.self) { i in
                        Group {
                            if let image = UIImage(data: gallery.images[i]) {
                                ZoomableImageView(image: image, isCurrent: i == index) { zoomed in
                                    if i == index { isZoomed = zoomed }
                                }
                            } else {
                                Image(systemName: "photo")
                                    .font(.largeTitle).foregroundColor(.white.opacity(0.35))
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                .onChange(of: index) { _ in isZoomed = false }

                topBar
            }
        }
        .ignoresSafeArea()
        // A zoomed image is panned vertically; without this the sheet's drag-to-dismiss
        // would swallow that gesture and close the viewer instead.
        .interactiveDismissDisabled(isZoomed)
    }

    private var topBar: some View {
        HStack {
            // Only meaningful with something to page to — and it is the only hint that
            // paging exists at all.
            if gallery.images.count > 1 {
                Text("\(index + 1) / \(gallery.images.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.45)).clipShape(Capsule())
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.45)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

// MARK: - ZoomableImageView

// One page of the gallery. Zooming is a `UIScrollView` rather than SwiftUI's
// MagnificationGesture + DragGesture, because a SwiftUI drag would have to out-prioritise the
// page view controller's own pan on every single swipe. Nested scroll views already settle
// that in UIKit: the inner one pans the zoomed image, and once it is back at its edge the
// next swipe pages as usual.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Pages swiped away from are reset, so coming back to one starts unzoomed.
    let isCurrent: Bool
    let onZoomChange: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutImage() }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        if !isCurrent && scroll.zoomScale != scroll.minimumZoomScale {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomScrollView?
        weak var imageView: UIImageView?
        var onZoomChange: (Bool) -> Void

        init(onZoomChange: @escaping (Bool) -> Void) { self.onZoomChange = onZoomChange }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
            onZoomChange(scrollView.zoomScale > scrollView.minimumZoomScale)
        }

        /// Sizes the image view to the aspect-fit rect instead of the full bounds, so zooming
        /// magnifies the picture rather than the letterbox bars around it.
        func layoutImage() {
            guard let scroll = scrollView, let imageView, let image = imageView.image,
                  scroll.bounds.width > 0, scroll.bounds.height > 0,
                  image.size.width > 0, image.size.height > 0 else { return }
            if scroll.zoomScale == scroll.minimumZoomScale {
                let fit = min(scroll.bounds.width / image.size.width,
                              scroll.bounds.height / image.size.height)
                let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                imageView.frame = CGRect(origin: .zero, size: size)
                scroll.contentSize = size
            }
            centerContent()
        }

        /// Keeps the image centred while it is smaller than the viewport.
        private func centerContent() {
            guard let scroll = scrollView else { return }
            let x = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
            let y = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                // Zoom in on the tapped point rather than the centre.
                let target: CGFloat = 2.5
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / target,
                                  height: scroll.bounds.height / target)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

// UIScrollView only knows its real size after layout, and SwiftUI gives no hook for that —
// updateUIView can run before the frame is set. This reports it instead.
private final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - ImageSendConfirmView
// Second-step confirmation shown before an image is actually sent. Shared by every
// image source (library, camera, meme, clipboard) so each send is double-confirmed.
private struct ImageSendConfirmView: View {
    let images: [UIImage]
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(images.count > 1 ? "Send \(images.count) images?" : "Send this image?")
                .font(.headline)
                .padding(.top, 20)

            if images.count > 1 {
                TabView {
                    ForEach(images.indices, id: \.self) { i in
                        Image(uiImage: images[i])
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                }
                .tabViewStyle(.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(uiImage: images[0])
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.25))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
                Button(action: onSend) {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - AppAlert
// Single source of truth for all alerts on ContentView. Stacking multiple
// `.alert` modifiers caused orphaned presentation contexts that froze the UI.
private enum AppAlert: Identifiable {
    case blockedWord
    case copySuccess
    case pinRequest
    case heartRate(String)
    case voice(String)

    var id: String {
        switch self {
        case .blockedWord:  return "blockedWord"
        case .copySuccess:  return "copySuccess"
        case .pinRequest:   return "pinRequest"
        case .heartRate:    return "heartRate"
        case .voice:        return "voice"
        }
    }
}

// MARK: - New Line menu action
// UIMenuController (deprecated iOS 16 but still works) adds "New Line" to the
// text-selection popup. The action is forwarded via NotificationCenter so the
// UIKit responder chain doesn't need direct access to SwiftUI state.

private extension Notification.Name {
    static let insertNewLine = Notification.Name("Unspoken.insertNewLine")
}

extension UIResponder {
    @objc func unspokenInsertNewLine(_ sender: Any?) {
        NotificationCenter.default.post(name: .insertNewLine, object: nil)
    }
}

// MARK: - Input bar hit area

private extension View {
    /// Grows a control's touch target into the input bar's own padding *without* changing its
    /// layout size, so the bar keeps its height while the corners of the slot stay tappable.
    /// The positive padding widens the frame, `contentShape` claims it for hit testing, and the
    /// matching negative padding shrinks the reported layout size back to the original.
    func inputBarHitArea() -> some View {
        let insets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 3)
        return padding(insets)
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -insets.top, leading: -insets.leading,
                                bottom: -insets.bottom, trailing: -insets.trailing))
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText: String = ""
    @State private var activeAlert: AppAlert?
    @State private var heartPulse: Bool = false
    @State private var bgHeartScale: CGFloat = 1.0
    @State private var showTimestamps: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary
    // Voice input is a mode, not a button: the attachment menu swaps the whole input bar for
    // one full-width hold-to-talk target, so the push-to-talk gesture can't be mistouched.
    @State private var voiceMode: Bool = false
    // Mirrors UIPasteboard.general.hasImages. A `Menu`'s content is not guaranteed to be
    // rebuilt at present-time, so the flag is refreshed by notification instead of read inline.
    // (`hasImages` alone never triggers the system "Allow Paste" alert — only reading `.image`
    // does, which is what beginSystemPasteboardAccess still guards.)
    @State private var hasClipboardImage: Bool = false
    // The single sheet currently presented (picker / meme / confirm / fullscreen).
    @State private var activeSheet: ActiveSheet? = nil
    // Images awaiting the source sheet (picker / meme) to dismiss before the confirm sheet shows.
    @State private var stagedImages: [UIImage] = []
    @State private var quotedMessage: Message? = nil
    @State private var typingDebounceTimer: Timer?
    @State private var insertingNewLine: Bool = false
    @State private var showUnpinDialog: Bool = false

    var canSendMessage: Bool { viewModel.peerPublicKey != nil }
    // A voice message needs somewhere to land: an online peer, or a pinned room where the
    // server can queue it. Non-pinned + offline peer means the room is gone.
    var canUseVoice: Bool { viewModel.peerPublicKey != nil && (viewModel.peerIsOnline || viewModel.isPinned) }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.4)]),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 0) {
                    chatHeader
                    ScreenshotProtected { chatMessages }
                    if viewModel.isFarewell {
                        farewellBar
                    } else {
                        inputArea
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(item: $activeAlert) { alert -> Alert in
            switch alert {
            case .blockedWord:
                return Alert(
                    title: Text("Notice"),
                    message: Text("Message contains blocked words. Please modify and try again."),
                    dismissButton: .default(Text("OK"))
                )
            case .copySuccess:
                return Alert(
                    title: Text("Link Copied"),
                    message: Text("Room invitation link has been copied to clipboard."),
                    dismissButton: .default(Text("OK"))
                )
            case .pinRequest:
                return Alert(
                    title: Text("Pin Request"),
                    message: Text("Your peer wants to pin this room. Pinned rooms persist across sessions and support offline messaging. Accept?"),
                    primaryButton: .default(Text("Accept")) { viewModel.acceptPin() },
                    secondaryButton: .cancel(Text("Decline")) { viewModel.rejectPin() }
                )
            case .heartRate(let msg):
                return Alert(
                    title: Text("Heart Rate"),
                    message: Text(msg),
                    dismissButton: .default(Text("OK")) { viewModel.heartRateModeError = nil }
                )
            case .voice(let msg):
                return Alert(
                    title: Text("Voice"),
                    message: Text(msg),
                    dismissButton: .default(Text("OK")) { viewModel.voiceError = nil }
                )
            }
        }
        .confirmationDialog("Unpin this room?", isPresented: $showUnpinDialog, titleVisibility: .visible) {
            Button("Unpin", role: .destructive) { viewModel.unpinRoom(grace: true) }
            Button("Unpin & erase now", role: .destructive) { viewModel.unpinRoom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unpin leaves your peer 7 days to read the last messages, then everything is destroyed on both devices and the server. Erase now destroys everything immediately, including undelivered messages.")
        }
        .onChange(of: viewModel.pinRequestReceived) { newValue in
            if newValue && activeAlert == nil { activeAlert = .pinRequest }
        }
        .onChange(of: viewModel.heartRateModeError) { newValue in
            if let msg = newValue, activeAlert == nil { activeAlert = .heartRate(msg) }
        }
        .onChange(of: viewModel.voiceError) { newValue in
            if let msg = newValue, activeAlert == nil { activeAlert = .voice(msg) }
        }
        // Single sheet modifier for every presentation. When a source sheet (picker / meme)
        // dismisses with a staged image, onDismiss chains straight into the confirm sheet.
        .sheet(item: $activeSheet, onDismiss: {
            viewModel.endSystemPasteboardAccess()
            if !stagedImages.isEmpty {
                let imgs = stagedImages
                stagedImages = []
                activeSheet = .confirmImage(IdentifiableImages(images: imgs))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isTextFieldFocused = true }
            }
        }) { sheet in
            switch sheet {
            case .imagePicker:
                if imagePickerSource == .camera {
                    ImagePicker(sourceType: .camera) { image in
                        stagedImages = [image]
                        activeSheet = nil
                    }
                } else {
                    MultiImagePicker { images in
                        stagedImages = images
                        activeSheet = nil
                    }
                }
            case .memeSearch:
                MemeSearchView { image in
                    // onSend fires off the main thread; hop to main before touching SwiftUI state.
                    DispatchQueue.main.async { stagedImages = [image] }
                }
            case .confirmImage(let item):
                ImageSendConfirmView(
                    images: item.images,
                    onCancel: { activeSheet = nil },
                    onSend: {
                        let captured = quotedMessage
                        quotedMessage = nil
                        activeSheet = nil
                        DispatchQueue.global(qos: .userInitiated).async {
                            // Send one by one, in selection order; only the first carries the quote.
                            for (index, image) in item.images.enumerated() {
                                guard let data = processImageForSending(image) else { continue }
                                let quote = index == 0 ? captured : nil
                                DispatchQueue.main.async { viewModel.sendImage(data, quotedMessage: quote) }
                            }
                        }
                    }
                )
            case .fullScreenImage(let gallery):
                ImageGalleryView(gallery: gallery) { activeSheet = nil }
            }
        }
    }

    // MARK: - Chat Header

    var chatHeader: some View {
        HStack {
            if viewModel.isFarewell {
                Image(systemName: "pin.slash").foregroundColor(.white.opacity(0.5)).font(.caption)
            } else if viewModel.isPinned {
                Image(systemName: "pin.fill").foregroundColor(.yellow).font(.caption)
            }
            if viewModel.isFarewell {
                Text("Room: \(viewModel.roomId) · Ended").font(.headline).foregroundColor(.white.opacity(0.7))
            } else if viewModel.isReconnecting {
                Text("Reconnecting...").font(.headline).foregroundColor(.yellow)
            } else {
                Text("Room: \(viewModel.roomId)").font(.headline).foregroundColor(.white)
            }
            if viewModel.isPinned && !viewModel.isFarewell {
                Circle()
                    .fill(viewModel.peerIsOnline ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }
            Spacer()

            if !viewModel.isPinned && !viewModel.isFarewell && viewModel.peerPublicKey != nil {
                Button(action: { viewModel.requestPin() }) {
                    Image(systemName: "pin")
                        .foregroundColor(viewModel.pinRequestPending ? .gray : .white)
                }
                .disabled(viewModel.pinRequestPending)
            }

            if viewModel.role == "host" && !viewModel.isPinned && !viewModel.isFarewell {
                Button(action: {
                    let url = "unspoken://\(viewModel.serverHost):\(viewModel.serverPort)/\(viewModel.roomId)"
                    UIPasteboard.general.string = url
                    activeAlert = .copySuccess
                }) {
                    Image(systemName: "link").foregroundColor(.white)
                }
            }

            if viewModel.canUseHeartRateMode || viewModel.isHeartRateMode || viewModel.peerBPM != nil {
                Button(action: {
                    if viewModel.isHeartRateMode { viewModel.stopHeartRateMode() }
                    else { viewModel.startHeartRateMode() }
                }) {
                    HStack(spacing: 3) {
                        if let peerBPM = viewModel.peerBPM {
                            Text("\(peerBPM)").font(.caption.bold())
                                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8))
                        }
                        Image(systemName: viewModel.isHeartRateMode || viewModel.peerBPM != nil ? "heart.fill" : "heart")
                            .foregroundColor(viewModel.isHeartRateMode ? .red : (viewModel.peerBPM != nil ? Color(red: 1.0, green: 0.6, blue: 0.8) : .white))
                            .scaleEffect(heartPulse ? 1.2 : 1.0)
                            .onChange(of: viewModel.isHeartRateMode) { active in
                                if active {
                                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { heartPulse = true }
                                } else {
                                    withAnimation { heartPulse = false }
                                }
                            }
                        if viewModel.isHeartRateMode, let bpm = viewModel.currentBPM {
                            Text("\(bpm)").font(.caption.bold()).foregroundColor(.red)
                        }
                    }
                }
                .disabled(!viewModel.canUseHeartRateMode)
            }

            Spacer().frame(width: 12)

            if viewModel.isFarewell {
                Button(action: { viewModel.dismissFarewell() }) {
                    Text("Close").foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.8)).cornerRadius(8)
                }
                .disabled(viewModel.farewellDraining)
                .opacity(viewModel.farewellDraining ? 0.5 : 1)
            } else if viewModel.isPinned {
                Button(action: { viewModel.leaveRoom() }) {
                    Text("Leave").foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.orange.opacity(0.8)).cornerRadius(8)
                }
                Button(action: { showUnpinDialog = true }) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(6)
                }
            } else {
                Button(action: { viewModel.leaveRoom() }) {
                    Text("Leave").foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.8)).cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.2))
    }

    /// Opens the full-screen viewer on `message`, with every other image in the conversation
    /// loaded alongside it so the user can page between them.
    private func openGallery(from message: Message) {
        let shots = viewModel.messages.filter { $0.imageData != nil }
        guard let start = shots.firstIndex(where: { $0.id == message.id }) else { return }
        activeSheet = .fullScreenImage(
            ImageGallery(images: shots.compactMap(\.imageData), startIndex: start)
        )
    }

    // MARK: - Chat Messages

    var chatMessages: some View {
        ZStack {
            // Background heartbeat animation (receiver side)
            ZStack {
                Image(systemName: "heart.fill").font(.system(size: 220)).foregroundColor(.white).opacity(0.22)
                Image(systemName: "heart.fill").font(.system(size: 185))
                    .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8)).opacity(0.55)
            }
            .opacity(viewModel.peerBPM != nil ? 1 : 0)
            .scaleEffect(bgHeartScale)
            .animation(.easeInOut(duration: 0.6), value: viewModel.peerBPM != nil)
            .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.messages) { message in
                            MessageView(message: message, voicePlayer: viewModel.voiceMessagePlayer, onReport: {
                                viewModel.reportUser()
                            }, showReport: !viewModel.isPinned, showTimestamp: showTimestamps, onImageTap: {
                                openGallery(from: message)
                            }, onQuote: {
                                quotedMessage = message
                                isTextFieldFocused = true
                            })
                        }
                        if !viewModel.typingContent.isEmpty {
                            MessageView(
                                message: Message(content: viewModel.typingContent, isFromMe: false, isTyping: true),
                                voicePlayer: viewModel.voiceMessagePlayer,
                                onReport: { viewModel.reportUser() },
                                showReport: !viewModel.isPinned
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 8)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.height) < abs(value.translation.width) else { return }
                            if value.translation.width < 0 {
                                withAnimation(.easeInOut(duration: 0.2)) { showTimestamps = true }
                            }
                        }
                        .onEnded { _ in withAnimation(.easeInOut(duration: 0.2)) { showTimestamps = false } }
                )
                .onChange(of: viewModel.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: viewModel.typingContent) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .onChange(of: viewModel.peerLubTick) { _ in
            withAnimation(.easeOut(duration: 0.08)) { bgHeartScale = 1.15 }
        }
        .onChange(of: viewModel.peerDubTick) { _ in
            withAnimation(.easeOut(duration: 0.06)) { bgHeartScale = 1.08 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.25)) { bgHeartScale = 1.0 }
            }
        }
        .onChange(of: viewModel.peerBPM) { newBPM in
            if newBPM == nil { bgHeartScale = 1.0 }
        }
        .simultaneousGesture(TapGesture().onEnded { isTextFieldFocused = false })
        .onAppear {
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: "New Line", action: #selector(UIResponder.unspokenInsertNewLine(_:)))
            ]
            hasClipboardImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            hasClipboardImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            hasClipboardImage = UIPasteboard.general.hasImages
        }
        .onDisappear {
            UIMenuController.shared.menuItems = nil
        }
    }

    // MARK: - Input Area

    var inputArea: some View {
        VStack(spacing: 0) {
            // Quote preview bar
            if let quoted = quotedMessage {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 3, height: 36)
                        .cornerRadius(1.5)
                    if let imgData = quoted.imageData, let uiImage = UIImage(data: imgData) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFill()
                            .frame(width: 36, height: 36).clipped().cornerRadius(4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quoted.isFromMe ? "You" : "Peer")
                            .font(.caption.bold()).foregroundColor(.white.opacity(0.85))
                        if quoted.imageData != nil {
                            Text("[Image]").font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        } else if quoted.audioData != nil {
                            Text("[Voice]").font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        } else {
                            Text(quoted.content).font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: { quotedMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption.bold()).foregroundColor(.white.opacity(0.6)).padding(6)
                    }
                }
                .frame(height: 50)
                .padding(.horizontal, 15)
                .background(Color.white.opacity(0.08))
            }

            HStack(spacing: 6) {
                if voiceMode {
                    // Leave voice mode. Recording several messages in a row is the common
                    // case, so sending one keeps the hold bar up; only this exits.
                    Button(action: { voiceMode = false }) {
                        Image(systemName: "xmark").foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.2)).clipShape(Circle())
                            .inputBarHitArea()
                    }
                    .disabled(viewModel.isTalking)

                    holdToTalkBar
                } else {
                    attachmentMenu

                    Group {
                        if #available(iOS 16, *) {
                            TextField(inputPlaceholder, text: $messageText, axis: .vertical)
                                .lineLimit(1...2)
                        } else {
                            TextField(inputPlaceholder, text: $messageText)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.2)).cornerRadius(18)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .focused($isTextFieldFocused)
                    .onChange(of: messageText) { newValue in
                        if newValue.hasSuffix("\n") {
                            if insertingNewLine {
                                // \n came from the "New Line" toolbar button — keep it
                                insertingNewLine = false
                            } else {
                                // \n came from the Return key — strip and send
                                messageText = String(newValue.dropLast())
                                if canSendMessage { sendMessage() }
                                return
                            }
                        }
                        guard canSendMessage else { return }
                        typingDebounceTimer?.invalidate()
                        typingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                            viewModel.sendTyping(content: newValue)
                        }
                    }
                    .onSubmit { if canSendMessage { sendMessage() } }
                    .disabled(!canSendMessage)
                    .onReceive(NotificationCenter.default.publisher(for: .insertNewLine)) { _ in
                        guard canSendMessage else { return }
                        insertingNewLine = true
                        messageText += "\n"
                    }

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill").foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.blue).clipShape(Circle())
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSendMessage)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: voiceMode)
        }
        .background(Color.black.opacity(0.1))
        // A voice message needs somewhere to land; if that goes away mid-mode, fall back to text.
        .onChange(of: canUseVoice) { usable in
            if !usable { voiceMode = false }
        }
    }

    /// The single "+" entry for everything that isn't typed text. A `Menu` (not a
    /// confirmationDialog) so the popover is anchored to the button instead of the screen
    /// bottom — on iOS 15 `.popover` still degrades to a sheet on iPhone, so this is the only
    /// native way to get that anchoring.
    var attachmentMenu: some View {
        // Declared bottom-up on purpose. UIKit orders menu items by distance from the anchor,
        // so a menu opening upwards — which this one always does, sitting on the input bar —
        // renders the first declared item nearest the button and the rest above it. Reading the
        // list below in reverse gives what the user actually sees:
        //   Take Photo / Photo Library / Send Meme / Paste Image / —— / Voice Message
        // with Voice Message closest to the finger.
        Menu {
            if canUseVoice {
                Button(action: { isTextFieldFocused = false; voiceMode = true }) {
                    Label("Voice Message", systemImage: "mic.fill")
                }
                Divider()
            }
            if hasClipboardImage {
                Button(action: {
                    // Reading the clipboard image triggers the system "Allow Paste" alert on
                    // iOS 16+, which briefly resigns active. Tell the view model to skip the
                    // pinned-room privacy auto-lock for that transient interruption, otherwise
                    // the chat (and this confirm sheet) gets torn down. See ChatViewModel.
                    viewModel.beginSystemPasteboardAccess()
                    if let img = UIPasteboard.general.image {
                        activeSheet = .confirmImage(IdentifiableImages(images: [img]))
                    } else {
                        viewModel.endSystemPasteboardAccess()
                    }
                }) {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
            }
            Button(action: { activeSheet = .memeSearch }) {
                Label("Send Meme", systemImage: "face.smiling")
            }
            Button(action: { imagePickerSource = .photoLibrary; activeSheet = .imagePicker }) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(action: { imagePickerSource = .camera; activeSheet = .imagePicker }) {
                    Label("Take Photo", systemImage: "camera.fill")
                }
            }
        } label: {
            Image(systemName: "plus").foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.2)).clipShape(Circle())
                .inputBarHitArea()
        }
        .disabled(!canSendMessage)
    }

    /// Push-to-talk: hold to record a voice message, release to send. Full width so the
    /// gesture has a target that can't be hit by accident.
    var holdToTalkBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isTalking ? "waveform" : "mic.fill")
            Text(viewModel.isTalking ? "Release to send" : "Hold to Talk")
                .fontWeight(.semibold)
            if viewModel.isTalking {
                Circle().fill(Color.red).frame(width: 8, height: 8)
            }
        }
        .foregroundColor(viewModel.isTalking ? .red : .white)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(viewModel.isTalking ? Color.red.opacity(0.25) : Color.white.opacity(0.2))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.3), lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: viewModel.isTalking)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in viewModel.startTalking() }
                .onEnded { _ in viewModel.stopTalking() }
        )
    }

    // MARK: - Farewell Bar

    /// Replaces the input bar once the room has ended: nothing to send, one way out.
    var farewellBar: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.farewellDraining ? "arrow.down.circle" : "lock.fill")
                .foregroundColor(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 3) {
                Text(farewellTitle)
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.9))
                Text(farewellSubtitle)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: { viewModel.dismissFarewell() }) {
                Text("Close")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.red.opacity(0.8)).cornerRadius(10)
            }
            .disabled(viewModel.farewellDraining)
            .opacity(viewModel.farewellDraining ? 0.5 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }

    private var farewellTitle: String {
        if viewModel.farewellDraining { return "Delivering the last messages…" }
        return viewModel.farewell == .hostClosed ? "The host closed this room." : "Your peer unpinned this room."
    }

    private var farewellSubtitle: String {
        if viewModel.farewellDraining {
            return "Hang on — the room closes when you're done reading."
        }
        if let until = viewModel.farewellGraceUntil {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "These messages live only on this screen. Closing erases them — and so does \(formatter.string(from: until))."
        }
        return "These messages live only on this screen. They are erased when you close."
    }

    private var inputPlaceholder: String {
        if !canSendMessage { return "Waiting for peer to join..." }
        if viewModel.isPinned && !viewModel.peerIsOnline { return "Message (peer offline, will be delivered later)" }
        return "Type a message"
    }

    // iOS app store review requirement
    func canSend(content: String) -> Bool {
        let blockedWords = ["badword1", "badword2", "fuck", "shit", "ass", "asshole", "bastard", "bitch", "damn", "dick", "douche", "fag", "faggot", "hell", "piss", "slut", "whore", "cunt", "crap", "jerk", "balls", "prick", "cock", "wanker", "retard", "moron", "bloody", "bollocks"]
        for word in blockedWords where content.lowercased().contains(word) { return false }
        return true
    }

    private func sendMessage() {
        guard canSend(content: messageText) else { activeAlert = .blockedWord; return }
        if canSendMessage && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.sendMessage(content: messageText, quotedMessage: quotedMessage)
            messageText = ""
            quotedMessage = nil
            isTextFieldFocused = true
        }
    }

    private func clearMessage() { messageText = "" }
}
