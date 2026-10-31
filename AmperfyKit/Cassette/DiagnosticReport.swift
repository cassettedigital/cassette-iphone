//
//  DiagnosticReport.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 2 (spine report envelope + mappers).
//
//  The wire model for POST /api/diagnostics/reports (schema_version 1). One
//  `DiagnosticReport` is one fault event (a crash / hang / an explicit export).
//  All large blobs — the full MetricKit payload and the 2,000-entry rolling
//  trace — are DECLARED here as attachments and shipped out-of-band via the
//  two-step presign flow; the inline `context` carries only small state + the
//  latest ~30 breadcrumbs so the JSON stays comfortably under the 64KB inline
//  cap the spine enforces.
//
//  Also here: the small helpers that turn a MetricKit crash file on disk into a
//  report (`DiagnosticCrashPayload`) and the persisted bookkeeping that keeps a
//  crash file from being pruned before it has been uploaded
//  (`DiagnosticUploadLedger`).
//

import Foundation

// MARK: - DiagnosticReport

/// The POST body for the diagnostics spine. Snake-cased on the wire to match the
/// server contract. `Encodable` only — the client never decodes one of these.
public struct DiagnosticReport: Encodable {
  public var schemaVersion: Int = 1
  public var idempotencyKey: String
  public var reportType: String
  public var platform: String = "ios"
  public var component: String?
  public var appVersion: String
  public var appBuild: String?
  public var osName: String?
  public var osVersion: String?
  public var deviceModel: String?
  public var deviceId: String?
  public var installId: String
  public var occurredAt: String
  public var severity: String?
  public var title: String?
  public var fingerprint: String?
  public var userMessage: String?
  public var context: JSONValue?
  public var crashSummary: JSONValue?
  public var consent: DiagnosticConsent?
  public var clientMeta: JSONValue?
  public var attachments: [DiagnosticAttachmentDeclaration]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case idempotencyKey = "idempotency_key"
    case reportType = "report_type"
    case platform
    case component
    case appVersion = "app_version"
    case appBuild = "app_build"
    case osName = "os_name"
    case osVersion = "os_version"
    case deviceModel = "device_model"
    case deviceId = "device_id"
    case installId = "install_id"
    case occurredAt = "occurred_at"
    case severity
    case title
    case fingerprint
    case userMessage = "user_message"
    case context
    case crashSummary = "crash_summary"
    case consent
    case clientMeta = "client_meta"
    case attachments
  }

  public init(
    idempotencyKey: String,
    reportType: String,
    appVersion: String,
    installId: String,
    occurredAt: String
  ) {
    self.idempotencyKey = idempotencyKey
    self.reportType = reportType
    self.appVersion = appVersion
    self.installId = installId
    self.occurredAt = occurredAt
  }
}

// MARK: - DiagnosticConsent

/// Consent block. Crashes/hangs auto-upload as OPT-OUT (`user_consented=false`);
/// an explicit user-driven diagnostic export is `user_consented=true`.
public struct DiagnosticConsent: Encodable {
  public var userConsented: Bool
  public var uploadEnabled: Bool
  public var containsPii: Bool
  public var redacted: Bool

  enum CodingKeys: String, CodingKey {
    case userConsented = "user_consented"
    case uploadEnabled = "upload_enabled"
    case containsPii = "contains_pii"
    case redacted
  }

  public init(userConsented: Bool, uploadEnabled: Bool, containsPii: Bool, redacted: Bool) {
    self.userConsented = userConsented
    self.uploadEnabled = uploadEnabled
    self.containsPii = containsPii
    self.redacted = redacted
  }
}

// MARK: - DiagnosticAttachmentDeclaration

/// Declares a big blob the client will PUT out-of-band. The server responds with
/// a presigned URL per declared slot. Slots: `rolling_trace`, `metrickit_crash`,
/// `metrickit_metrics`, `full_export`, `screenshot`.
public struct DiagnosticAttachmentDeclaration: Encodable {
  public var slot: String
  public var kind: String
  public var contentType: String?
  public var byteSize: Int?

  enum CodingKeys: String, CodingKey {
    case slot
    case kind
    case contentType = "content_type"
    case byteSize = "byte_size"
  }

  public init(slot: String, kind: String, contentType: String? = nil, byteSize: Int? = nil) {
    self.slot = slot
    self.kind = kind
    self.contentType = contentType
    self.byteSize = byteSize
  }
}

// MARK: - DiagnosticReportResponse

/// 200 response from POST /api/diagnostics/reports. camelCase on the wire (per
/// the spine contract) so no custom keys are needed.
public struct DiagnosticReportResponse: Decodable {
  public let ok: Bool
  public let id: String
  public let deduped: Bool
  public let attachmentUploads: [DiagnosticAttachmentUpload]?
}

// MARK: - DiagnosticAttachmentUpload

/// One presigned attachment target the client must PUT to, then acknowledge via
/// the `/attachments/complete` endpoint.
public struct DiagnosticAttachmentUpload: Decodable {
  public let slot: String
  public let r2Key: String
  public let presignedUrl: String
  public let expiresAt: String?
}

// MARK: - DiagnosticUploadLedger

/// Persisted bookkeeping so a crash file is never dropped unsent. A crash file is
/// only pruned once its name is in the uploaded set; and each file mints its
/// idempotency key exactly once (reused on retry) so a redelivered report dedups
/// server-side instead of duplicating.
public enum DiagnosticUploadLedger {
  private static let uploadedKey = "cassette.diagnostics.uploadedCrashFiles"
  private static let idempotencyKey = "cassette.diagnostics.reportIdempotencyKeys"

  // MARK: Uploaded set

  public static func isUploaded(_ filename: String) -> Bool {
    uploadedFilenames().contains(filename)
  }

  public static func markUploaded(_ filename: String) {
    var set = uploadedFilenames()
    guard set.insert(filename).inserted else { return }
    UserDefaults.standard.set(Array(set), forKey: uploadedKey)
  }

  /// Drop bookkeeping for a filename once its crash file has been pruned, so the
  /// two UserDefaults collections don't accumulate dead entries forever.
  public static func forget(_ filename: String) {
    var set = uploadedFilenames()
    if set.remove(filename) != nil {
      UserDefaults.standard.set(Array(set), forKey: uploadedKey)
    }
    var keys = idempotencyMap()
    if keys.removeValue(forKey: filename) != nil {
      UserDefaults.standard.set(keys, forKey: idempotencyKey)
    }
  }

  private static func uploadedFilenames() -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
  }

  // MARK: Idempotency keys

  /// The report's idempotency key for a given crash file — minted once and then
  /// stable, so a retried upload reuses it and the server dedups.
  public static func idempotencyKey(for filename: String) -> String {
    var map = idempotencyMap()
    if let existing = map[filename] { return existing }
    let minted = UUID().uuidString
    map[filename] = minted
    UserDefaults.standard.set(map, forKey: idempotencyKey)
    return minted
  }

  private static func idempotencyMap() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: idempotencyKey) as? [String: String] ?? [:]
  }
}

// MARK: - DiagnosticCrashPayload

/// A MetricKit diagnostic file (`crash-*.json`) distilled into just what a report
/// needs: the true on-device fault time, the precise device model + OS the crash
/// carries (better than `UIDevice.current.model`'s generic "iPhone"), and a small
/// crash summary head. Large detail stays in the file and rides as an attachment.
public struct DiagnosticCrashPayload {
  public let reportType: String
  public let severity: String
  public let occurredAt: Date
  public let deviceModel: String?
  public let osVersion: String?
  public let appVersion: String?
  public let appBuild: String?
  public let title: String?
  public let fingerprint: String?
  public let summary: JSONValue?

  /// MetricKit encodes timestamps as `"yyyy-MM-dd HH:mm:ss"` (not ISO-8601) in the phone's own
  /// time zone, with no offset. Read as UTC they landed five hours early for a Central-time
  /// phone (BUG-754: a 10:46 crash stored as 05:46).
  private static let metricKitTimestamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  /// Parse a MetricKit diagnostic file. Returns nil only if the file can't be
  /// read or isn't a JSON object; an object with none of the recognised
  /// diagnostic arrays still yields a minimal `unhandled_error` report.
  public init?(fileURL: URL) {
    guard let data = try? Data(contentsOf: fileURL),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return nil
    }

    // occurred_at: the payload's own end timestamp is when the collection window
    // (i.e. the crash) closed — NOT the next-launch file write time. Fall back to
    // the begin stamp, then the file's creation date, then now.
    let stampString = (root["timeStampEnd"] as? String) ?? (root["timeStampBegin"] as? String)
    if let stampString, let parsed = Self.metricKitTimestamp.date(from: stampString) {
      self.occurredAt = parsed
    } else if let created = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?
      .creationDate {
      self.occurredAt = created
    } else {
      self.occurredAt = Date()
    }

    // Classify by which diagnostic array is present. A single file can carry
    // several; crash is the headline, then hang, then the exception kinds.
    let crash = (root["crashDiagnostics"] as? [[String: Any]])?.first
    let hang = (root["hangDiagnostics"] as? [[String: Any]])?.first
    let cpu = (root["cpuExceptionDiagnostics"] as? [[String: Any]])?.first
    let disk = (root["diskWriteExceptionDiagnostics"] as? [[String: Any]])?.first

    let primary: [String: Any]?
    if let crash {
      self.reportType = "crash"
      self.severity = "fatal"
      primary = crash
    } else if let hang {
      self.reportType = "hang"
      self.severity = "warning"
      primary = hang
    } else if let cpu {
      self.reportType = "unhandled_error"
      self.severity = "error"
      primary = cpu
    } else if let disk {
      self.reportType = "unhandled_error"
      self.severity = "error"
      primary = disk
    } else {
      self.reportType = "unhandled_error"
      self.severity = "error"
      primary = nil
    }

    let meta = primary?["diagnosticMetaData"] as? [String: Any]
    self.deviceModel = meta?["deviceType"] as? String
    self.osVersion = meta?["osVersion"] as? String
    self.appVersion = meta?["appVersion"] as? String
    self.appBuild = meta?["appBuildVersion"] as? String

    // Small crash-summary head: the metadata fault fields + the top ~20 frames of
    // the attributed thread. The full call-stack tree stays in the attachment.
    let exceptionType = meta?["exceptionType"] as? Int
    let exceptionCode = meta?["exceptionCode"] as? Int
    let signal = meta?["signal"] as? Int
    let termination = meta?["terminationReason"] as? String
    let frames: [String] = (primary?["callStackTree"] as? [String: Any])
      .map { Self.topFrames($0, limit: 20) } ?? []

    var summaryFields: [String: JSONValue] = [:]
    if let exceptionType { summaryFields["exception_type"] = .number(Double(exceptionType)) }
    if let exceptionCode { summaryFields["exception_code"] = .number(Double(exceptionCode)) }
    if let signal { summaryFields["signal"] = .number(Double(signal)) }
    if let termination { summaryFields["termination_reason"] = .string(termination) }
    if !frames.isEmpty { summaryFields["top_frames"] = .array(frames.map { .string($0) }) }
    self.summary = summaryFields.isEmpty ? nil : .object(summaryFields)

    // A compact, human-readable title + a deterministic fingerprint so identical
    // crashes group. Both are best-effort from the stable metadata fields.
    let topFrame = frames.first
    if let termination, !termination.isEmpty {
      self.title = termination
    } else if let signal {
      self.title = "MetricKit \(reportType) (signal \(signal))"
    } else {
      self.title = "MetricKit \(reportType)"
    }
    let fingerprintParts = [
      exceptionType.map(String.init),
      signal.map(String.init),
      topFrame,
    ].compactMap { $0 }
    self.fingerprint = fingerprintParts.isEmpty ? nil : fingerprintParts.joined(separator: "|")
  }

  /// Depth-first walk of the attributed thread's frames, capped at `limit`.
  private static func topFrames(_ callStackTree: [String: Any], limit: Int) -> [String] {
    guard let callStacks = callStackTree["callStacks"] as? [[String: Any]],
          let first = callStacks.first,
          let roots = first["callStackRootFrames"] as? [[String: Any]] else { return [] }
    var out: [String] = []
    func walk(_ frames: [[String: Any]]) {
      for frame in frames {
        if out.count >= limit { return }
        let name = frame["binaryName"] as? String ?? "?"
        if let offset = frame["offsetIntoBinaryTextSegment"] as? Int {
          out.append("\(name)+\(offset)")
        } else {
          out.append(name)
        }
        if let sub = frame["subFrames"] as? [[String: Any]] { walk(sub) }
      }
    }
    walk(roots)
    return out
  }
}

// MARK: - Breadcrumbs

extension DiagnosticReport {
  /// The latest `limit` breadcrumbs, shaped small for inline `context`. Only the
  /// timestamp, category and message travel inline; the full rolling trace rides
  /// as the `rolling_trace` attachment.
  public static func breadcrumbContext(
    _ entries: [DiagnosticEntry],
    limit: Int = 30,
    extra: [String: JSONValue] = [:]
  )
    -> JSONValue {
    let iso = ISO8601DateFormatter()
    let latest = entries.suffix(limit).map { entry -> JSONValue in
      .object([
        "t": .string(iso.string(from: entry.timestamp)),
        "c": .string(entry.category.rawValue),
        "m": .string(entry.message),
      ])
    }
    var object = extra
    object["breadcrumbs"] = .array(latest)
    return .object(object)
  }
}
