//
//  SupportSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - SupportSettingsView

/// Cassette Diagnostics Feature B/C: the founder-facing "Report a problem"
/// outlet. Replaces upstream Amperfy's MFMailCompose "Send feedback" (which
/// depended on a configured Mail account and shipped a JSON attachment nobody
/// read) with an IN-APP form that POSTs `report_type=user_feedback` straight to
/// the diagnostics spine — landing next to crashes/hangs in /admin/diagnostics
/// with a "User message" panel. Manual feedback is user-initiated, so it is sent
/// regardless of the diagnostics opt-out. An optional key-window screenshot rides
/// along as an `image/png` attachment.
struct SupportSettingsView: View {
  @State
  private var feedbackText = ""
  @State
  private var includeScreenshot = true
  @State
  private var sendState: SendState = .idle

  private enum SendState: Equatable {
    case idle
    case sending
    case succeeded
    case failed
  }

  private var canSend: Bool {
    sendState != .sending &&
      !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    SettingsList {
      SettingsSection(
        content: {
          // Multi-line free text. `.vertical` axis lets the field grow with the
          // message; the placeholder doubles as the prompt.
          TextField(
            "Describe the problem, or share any feedback…",
            text: $feedbackText,
            axis: .vertical
          )
          .lineLimit(4 ... 10)
          .disabled(sendState == .sending)

          Toggle("Include a screenshot of the app", isOn: $includeScreenshot)
            .disabled(sendState == .sending)

          Button {
            send()
          } label: {
            switch sendState {
            case .idle:
              Label("Send to Cassette", systemImage: "paperplane")
            case .sending:
              Label("Sending…", systemImage: "paperplane")
            case .succeeded:
              Label("Sent. Thank you", systemImage: "checkmark.circle")
            case .failed:
              Label("Couldn't send, tap to retry", systemImage: "exclamationmark.circle")
            }
          }
          .disabled(!canSend)
        },
        footer: "Sends your message straight to Cassette. A screenshot, if included, helps us see what you saw. No Mail account needed."
      )
      // cassette §G: Event Log moved to the Advanced screen.
    }
    .navigationTitle("Report a problem")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      appDelegate.userStatistics.visited(.settingsSupport)
    }
  }

  // MARK: Send

  private func send() {
    guard canSend else { return }
    let message = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)

    // Capture on the main actor, BEFORE flipping to `.sending`, so the snapshot is
    // of the app as the user left it. Device fields + breadcrumbs are read here
    // too, then handed to the off-main-actor uploader.
    // The screen as it was when Settings opened (I-S6): the problem, not this form.
    let screenshot = includeScreenshot ? (Self.screenBeforeSettings ?? Self.captureKeyWindowPNG()) : nil
    let device = UIDevice.current
    let deviceModel = device.model
    let osVersion = device.systemVersion
    let breadcrumbs = DiagnosticLog.shared.snapshot()

    sendState = .sending
    UISelectionFeedbackGenerator().selectionChanged()

    Task {
      let ok = await DiagnosticsConfig.sharedUploader.submitFeedback(
        message: message,
        screenshot: screenshot,
        deviceModel: deviceModel,
        osVersion: osVersion,
        breadcrumbs: breadcrumbs
      )
      await MainActor.run {
        sendState = ok ? .succeeded : .failed
        if ok { feedbackText = "" }
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
      }
    }
  }

  /// Snapshot the current key window as PNG. Feature C: the manual-feedback
  /// screenshot. Uses `drawHierarchy(afterScreenUpdates: false)` so it captures
  /// what's already on screen without forcing a re-render. Returns nil if no key
  /// window is resolvable (never fatal — feedback still sends text-only).
  /// What was on screen just before the Settings sheet opened, kept for Report a problem.
  @MainActor
  private(set) static var screenBeforeSettings: Data?

  /// Called as the Settings sheet is about to open, so the report shows the problem.
  @MainActor
  static func rememberScreenBeforeSettings() {
    screenBeforeSettings = captureKeyWindowPNG()
  }

  @MainActor
  private static func captureKeyWindowPNG() -> Data? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    guard let window else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
    return image.pngData()
  }
}

// MARK: - SupportSettingsView_Previews

struct SupportSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SupportSettingsView()
  }
}
