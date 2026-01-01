//
//  PreviewViewController.swift
//  ProjectorQuickLook
//
//  Created by Keegan DeWitt on 1/1/26.
//

import Cocoa
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView = NSImageView()

    override func loadView() {
        // Create the view programmatically
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Configure the image view
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        // Center the image view with a reasonable size
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.8),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, multiplier: 0.8),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 512),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 512)
        ])

        self.view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Load the DocumentIcon from the extension bundle
        if let iconImage = Bundle.main.image(forResource: "DocumentIcon") {
            await MainActor.run {
                imageView.image = iconImage
            }
        }
    }
}
