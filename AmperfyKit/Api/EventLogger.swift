//
//  EventLogger.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 16.05.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import Alamofire
import Foundation
import os.log
import UIKit

// MARK: - AmperfyLogStatusCode

public enum AmperfyLogStatusCode: Int {
  case downloadError = 1
  case playerError = 2
  case emailError = 3
  case internalError = 4
  case connectionError = 5
  case commonError = 6
  case info
}

// MARK: - AlertDisplayable

@MainActor
public protocol AlertDisplayable {
  func display(
    title: String,
    subtitle: String,
    style: LogEntryType,
    notificationBanner popupVC: UIViewController
  )
  func display(popup popupVC: UIViewController)
  func createPopupVC(
    topic: String,
    shortMessage: String,
    detailMessage: String,
    logType: LogEntryType
  ) -> UIViewController
}

// MARK: - EventLogger

@MainActor
public class EventLogger {
  public var supressAlerts = false

  private let log = OSLog(subsystem: "Amperfy", category: "EventLogger")
  public var alertDisplayer: AlertDisplayable?
  private let storage: PersistentStorage

  init(storage: PersistentStorage) {
    self.storage = storage
  }

  public func debug(topic: String, message: String) {
    report(
      topic: topic,
      statusCode: .info,
      shortMessage: message,
      detailMessage: message,
      logType: .debug,
      displayPopup: false
    )
  }

  public func info(topic: String, message: String, displayPopup: Bool = true) {
    report(
      topic: topic,
      statusCode: .info,
      shortMessage: message,
      detailMessage: message,
      logType: .info,
      displayPopup: displayPopup
    )
  }

  public func info(
    topic: String,
    statusCode: AmperfyLogStatusCode,
    message: String,
    displayPopup: Bool
  ) {
    report(
      topic: topic,
      statusCode: statusCode,
      shortMessage: message,
      detailMessage: message,
      logType: .info,
      displayPopup: displayPopup
    )
  }

  public func error(
    topic: String,
    statusCode: AmperfyLogStatusCode,
    message: String,
    displayPopup: Bool
  ) {
    report(
      topic: topic,
      statusCode: statusCode,
      shortMessage: message,
      detailMessage: message,
      logType: .error,
      displayPopup: displayPopup
    )
  }

  public func error(
    topic: String,
    statusCode: AmperfyLogStatusCode,
    shortMessage: String,
    detailMessage: String,
    displayPopup: Bool
  ) {
    report(
      topic: topic,
      statusCode: statusCode,
      shortMessage: shortMessage,
      detailMessage: detailMessage,
      logType: .error,
      displayPopup: displayPopup
    )
  }

  private func report(
    topic: String,
    statusCode: AmperfyLogStatusCode,
    shortMessage: String,
    detailMessage: String,
    logType: LogEntryType,
    displayPopup: Bool
  ) {
    saveAndDisplay(
      topic: topic,
      logType: logType,
      errorType: statusCode,
      statusCode: statusCode.rawValue,
      logMessage: topic + ": " + shortMessage,
      displayPopup: displayPopup,
      popupMessage: shortMessage,
      detailMessage: detailMessage
    )
  }

  /// cassette Patch 040: `isBackground` lets callers mark errors as
  /// originating from background work (tab-appear sync, scroll
  /// prefetch, autodownload) so they're persisted + os_log'd but
  /// never surface as a user-facing banner. Default stays `false`
  /// to preserve every existing call site's behavior.
  public func report(
    topic: String,
    error: Error,
    displayPopup: Bool = true,
    isBackground: Bool = false
  ) {
    if let apiError = error as? ResponseError {
      return report(
        topic: topic,
        error: apiError,
        displayPopup: displayPopup,
        isBackground: isBackground
      )
    }
    let shouldDisplay = displayPopup && !isBackground
    // cassette Patch 040: replace raw NSURLErrorDomain
    // localizedDescription with brand-voice copy for the banner.
    // The unfriendly text ("URLSessionTask failed with error...")
    // still goes into detailMessage so tap → NotificationDetailVC
    // surfaces the real error for debugging.
    let raw = error.localizedDescription
    let popupCopy = Self.bannerCopy(for: error, topic: topic)
    saveAndDisplay(
      topic: topic,
      logType: .error,
      errorType: .commonError,
      statusCode: 0,
      logMessage: topic + ": " + raw,
      displayPopup: shouldDisplay,
      popupMessage: popupCopy,
      detailMessage: raw
    )
  }

  public func report(
    topic: String,
    error: ResponseError,
    displayPopup: Bool,
    isBackground: Bool = false
  ) {
    var alertMessage = ""
    if error.statusCode > 0 {
      alertMessage += "Status code: \(error.statusCode)\n"
    }
    alertMessage += "\(error.message)"
    var detailMessage = "\(alertMessage)"
    if let cleansedURL = error.cleansedURL {
      detailMessage += "\n\nURL:\n\(cleansedURL.description)"
    }

    let isInfoError = error.type == .resource
    detailMessage += "\n\nError Content:\n" + error.asInfo(topic: topic).asJSONString()

    let shouldDisplay = displayPopup && !isBackground
    // cassette (UX pass 2026-10-20): the banner says what failed in a sentence; the status
    // code, server message, URL and JSON stay in the detail sheet a tap opens.
    saveAndDisplay(
      topic: topic,
      logType: isInfoError ? .info : .apiError,
      errorType: isInfoError ? .info : .connectionError,
      statusCode: error.statusCode,
      logMessage: error.message,
      displayPopup: shouldDisplay,
      popupMessage: "\(topic) didn't work. Tap for details.",
      detailMessage: detailMessage
    )
  }

  // MARK: - cassette Patch 040: brand-voice helpers

  /// True when `error` is a transient connectivity / availability
  /// failure against the user's Cassette Player (`NSURLErrorDomain`
  /// or matching CFNetwork code). These are the cases where the
  /// raw "URLSessionTask failed..." text is useless to the user
  /// and gets replaced with brand voice.
  private static func isNetworkConnectivityError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain { return true }
    if nsError.domain == (kCFErrorDomainCFNetwork as String) { return true }
    return false
  }

  /// The banner's sentence for `error`. A network failure gets plain words for what is out of
  /// reach (the phone offline, Cassette, or the person's computer), never the raw
  /// "URLSessionTask failed with error: ..." text, which stays in the detail a tap opens. The
  /// music server's calls go through Alamofire, which wraps the URL error, so the wrapper is
  /// looked through first; before, those reached the banner raw (BUG-972).
  /// The error a music-server call throws when its request fails: Alamofire's wrapper around
  /// the URL error. Built here for the tests, whose target doesn't link Alamofire.
  static func musicServerFailure(_ error: URLError) -> Error {
    AFError.sessionTaskFailed(error: error)
  }

  static func bannerCopy(for error: Error, topic: String) -> String {
    let underlying = (error as? AFError)?.underlyingError ?? error
    guard isNetworkConnectivityError(underlying) else { return error.localizedDescription }
    if topic == "Toggle Favorite" {
      return "Couldn't update your favorite. Try again in a moment."
    }
    let urlError = underlying as? URLError
    if urlError?.code == .notConnectedToInternet || urlError?.code == .dataNotAllowed {
      return "You're offline. Try again when you're connected."
    }
    if let host = urlError?.failingURL?.host?.lowercased(),
       host == "cassette.digital" || host.hasSuffix(".cassette.digital") {
      return "Cassette isn't answering. Try again in a moment."
    }
    return "Your computer isn't answering. Try again in a moment."
  }

  private func saveAndDisplay(
    topic: String,
    logType: LogEntryType,
    errorType: AmperfyLogStatusCode,
    statusCode: Int,
    logMessage: String,
    displayPopup: Bool,
    popupMessage: String,
    detailMessage: String
  ) {
    os_log("%s", log: self.log, type: Self.osLogType(for: logType), logMessage)
    // Cassette — Diagnostics Phase 1: mirror every reported event into the
    // in-memory rolling trace. This is in addition to the CoreData write below
    // (which is unchanged); the append is fire-and-return and never touches disk.
    DiagnosticLog.shared.log(
      DiagnosticCategory.forEventLog(topic: topic, isApiError: logType == .apiError),
      logMessage,
      context: statusCode != 0 ? ["statusCode": "\(statusCode)"] : nil
    )
    Task { @MainActor in
      do {
        try await storage.async.perform { asynCompanion in
          let logEntry = asynCompanion.library.createLogEntry()
          logEntry.type = logType
          logEntry.statusCode = statusCode
          logEntry.message = logMessage
          asynCompanion.saveContext()
        }
        if displayPopup {
          self.displayAlert(
            topic: topic,
            shortMessage: popupMessage,
            detailMessage: detailMessage,
            logType: logType
          )
        }
      } catch {
        // do nothing
      }
    }
  }

  private func displayAlert(
    topic: String,
    shortMessage: String,
    detailMessage: String,
    logType: LogEntryType
  ) {
    guard let displayer = alertDisplayer else { return }
    Task { @MainActor in
      guard !self.supressAlerts else { return }
      let popupVC = displayer.createPopupVC(
        topic: topic,
        shortMessage: shortMessage,
        detailMessage: detailMessage,
        logType: logType
      )
      displayer.display(
        title: topic,
        subtitle: shortMessage,
        style: logType,
        notificationBanner: popupVC
      )
    }
  }

  /// Cassette — Diagnostics Phase 1: the console line was hardcoded to `.error`
  /// for every entry, so OSLog severity didn't match the stored `LogEntryType`.
  /// Map it through so info/debug entries log at the right level.
  private static func osLogType(for logType: LogEntryType) -> OSLogType {
    switch logType {
    case .apiError, .error: return .error
    case .info: return .info
    case .debug: return .debug
    }
  }
}
