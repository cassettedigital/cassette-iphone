//
//  Utilities.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

import CoreData
import Foundation
import os.log
import UIKit

public typealias VoidFunctionCallback = () -> ()

// MARK: - CustomEquatable

public protocol CustomEquatable {
  func isEqualTo(_ other: CustomEquatable) -> Bool
}

extension CustomEquatable where Self: Equatable {
  public func isEqualTo(_ other: CustomEquatable) -> Bool {
    if let other = other as? Self { return self == other }
    return false
  }
}

// MARK: - Atomic

@propertyWrapper
public final class Atomic<Value>: Sendable {
  nonisolated(unsafe) private var value: Value
  private let lock = NSLock()

  public var wrappedValue: Value {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }

  public init(wrappedValue value: Value) {
    self.value = value
  }
}

extension Bool {
  public mutating func toggle() {
    self = !self
  }

  public static func random(probabilityForTrueInPercent probability: Float) -> Bool {
    Float.random(in: 0 ..< 100) <= probability
  }
}

extension Int16 {
  public static func isValid(value: Int) -> Bool {
    !((value < Int16.min) || (value > Int16.max))
  }
}

extension Int32 {
  public static func isValid(value: Int) -> Bool {
    !((value < Int32.min) || (value > Int32.max))
  }
}

extension Int64 {
  public var asByteString: String {
    ByteCountFormatter.string(
      fromByteCount: self,
      countStyle: ByteCountFormatter.CountStyle.decimal
    )
  }
}

extension Int {
  public mutating func setOtherRandomValue(in targetRange: ClosedRange<Int>) {
    var newValue = 0
    repeat {
      newValue = Int.random(in: targetRange)
    } while newValue == self
    self = newValue
  }

  public func roundDownToFractionOf(_ value: Int) -> Int {
    (self / value) * value
  }

  public var asColonDurationString: String {
    var hourString = ""
    let hours = self / (60 * 60)
    if hours > 0 {
      hourString += "\(hours):"
    }
    let minutes = (self - (hours * 60 * 60)) / 60
    let seconds = self - ((hours * 60 * 60) + (minutes * 60))
    if hourString.isEmpty {
      return String(format: "%01d", minutes) + ":" + String(format: "%02d", seconds)
    } else {
      return hourString + String(format: "%02d", minutes) + ":" + String(format: "%02d", seconds)
    }
  }

  public var asDurationShortString: String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(self))!
  }

  /// A record's length the way its page says it: whole minutes, "38 min", "65 min" (I-V6).
  public var asRecordMinutes: String {
    "\(Swift.max(1, Int((Double(self) / 60).rounded()))) min"
  }

  public var asDurationString: String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(self))!
  }

  public var asMinuteString: String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute]
    formatter.unitsStyle = .short
    return formatter.string(from: TimeInterval(self))!
  }

  public var asDayString: String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day]
    formatter.unitsStyle = .short
    return formatter.string(from: TimeInterval(self))!
  }
}

extension String {
  public func isFoundBy(searchText: String) -> Bool {
    lowercased().contains(searchText.lowercased())
  }

  public func isContainedIn(_ container: [String]) -> Bool {
    container.contains(self)
  }

  public var asIso8601Date: Date? {
    let dateFormatter = ISO8601DateFormatter()
    return dateFormatter.date(from: self)
  }

  public var asByteCount: Int? {
    guard !isEmpty else { return nil }
    if hasSuffix(" GB") {
      let stringSize = self[..<index(endIndex, offsetBy: -3)]
      guard let stringFloat = Float(stringSize) else { return nil }
      return Int(stringFloat * 1000 * 1000 * 1000)
    } else if hasSuffix(" MB") {
      let stringSize = self[..<index(endIndex, offsetBy: -3)]
      guard let stringFloat = Float(stringSize) else { return nil }
      return Int(stringFloat * 1000 * 1000)
    } else if hasSuffix(" KB") {
      let stringSize = self[..<index(endIndex, offsetBy: -3)]
      guard let stringFloat = Float(stringSize) else { return nil }
      return Int(stringFloat * 1000)
    } else if hasSuffix(" B") {
      let stringSize = self[..<index(endIndex, offsetBy: -2)]
      guard let stringFloat = Float(stringSize) else { return nil }
      return Int(stringFloat)
    } else {
      return nil
    }
  }

  public var asDurationInSeconds: Int? {
    let components = split { $0 == ":" }.compactMap { Int($0) }
    guard components.count == 3 else { return nil }
    return (components[0] * 60 * 24) + (components[1] * 60) + components[2]
  }

  public static var defaultSectionInital: String.Element {
    "?"
  }

  public var sectionInitial: String {
    guard !isEmpty else { return "?" }
    let initial = String(
      prefix(1).folding(options: .diacriticInsensitive, locale: nil)
        .uppercased()
    )
    if let _ = initial.rangeOfCharacter(from: CharacterSet.decimalDigits) {
      return "#"
    } else if let _ = initial
      .rangeOfCharacter(from: CharacterSet(charactersIn: String.uppercaseAsciiLetters)) {
      return initial
    } else if let _ = initial
      .rangeOfCharacter(from: CharacterSet.letters) { // japanese / chinese letters
      return "&"
    } else {
      return "?"
    }
  }

  /// The Library grid's letters in order: "#" first, then A to Z (phone-taste LETTERS).
  public static let libraryLetters: [String] = ["#"] + uppercaseAsciiLetters.map { String($0) }

  /// The characters a title may open with that the library's sort ignores.
  private static let librarySortKeyLeadingMarks: Set<Character> = [
    "\"", "\u{201C}", "\u{201D}", "'", "\u{2018}", "\u{2019}",
    "(", "[", "{", "<", "\u{00A1}", "\u{00BF}", ".",
  ]

  /// The library's sort key, ported from the phone-taste mock (data.ts sortKey): the title
  /// without leading whitespace, quotes, brackets or inverted marks, then without a leading
  /// "The ". "The Bends" sorts as "Bends", "(What's the Story)" as "What's the Story)".
  /// Computed in memory for the Library grid; nothing stored is read or rewritten, so
  /// `sectionInitial` and every saved section key stay as they are.
  public var librarySortKey: String {
    let marks = Self.librarySortKeyLeadingMarks
    var key = Substring(self).drop { $0.isWhitespace || marks.contains($0) }
    if key.prefix(3).lowercased() == "the", let next = key.dropFirst(3).first,
       next.isWhitespace {
      key = key.dropFirst(3).drop { $0.isWhitespace }
    }
    return String(key)
  }

  /// The letter a title files under in the Library grid (data.ts letterOf): the first
  /// character of `librarySortKey` with accents and case folded, so "Átta" is A. Anything
  /// that does not fold to A to Z (digits, symbols, other scripts, Ø) is "#".
  public var libraryLetter: String {
    Self.libraryLetter(forSortKey: librarySortKey)
  }

  /// `libraryLetter` for a key already made by `librarySortKey`. The key is not stripped
  /// again: "The (What)" keys as "(What)" and files under "#", as the mock does.
  public static func libraryLetter(forSortKey key: String) -> String {
    guard let first = key.first else { return "#" }
    let folded = String(first).folding(options: .diacriticInsensitive, locale: nil)
      .uppercased()
    guard let scalar = folded.unicodeScalars.first,
          scalar.value >= 0x41, scalar.value <= 0x5A else { return "#" }
    return String(Character(scalar))
  }

  public static var uppercaseAsciiLetters: String {
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  }

  public static func generateRandomString(ofLength length: Int) -> String {
    let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return String((0 ..< length).map { _ in letters.randomElement()! })
  }

  public func deletingPrefix(_ prefix: String) -> String {
    guard hasPrefix(prefix) else { return self }
    return String(dropFirst(prefix.count))
  }

  private var html2AttributedString: NSAttributedString? {
    Data(utf8).html2AttributedString
  }

  public var html2String: String {
    html2AttributedString?.string.html2AttributedString?.string ?? ""
  }
}

// MARK: - AlphabeticSectionCount

/// One fetched-results section as the CarPlay browse planner sees it: the one-character
/// section key (`sectionInitial`) and how many rows sit under it. Pure counts, no objects.
public struct AlphabeticSectionCount: Sendable, Equatable {
  public let name: String
  public let count: Int

  public init(name: String, count: Int) {
    self.name = name
    self.count = count
  }
}

// MARK: - AlphabeticBucket

/// A contiguous run of section keys that fits one CarPlay list, or one slice of a section
/// that is on its own too big for a list. Every entry of the library lands in exactly one
/// bucket. Buckets are values: a pushed range list carries the one it was planned from and
/// re-renders its keys against the live fetch controller without ever re-planning.
public struct AlphabeticBucket: Sendable, Equatable {
  public struct ChunkRef: Sendable, Equatable {
    /// 0-based slice index.
    public let index: Int
    /// How many slices the section was split into when planned.
    public let count: Int

    public init(index: Int, count: Int) {
      self.index = index
      self.count = count
    }
  }

  /// Contiguous fetch-controller keys in fetch-controller order.
  public let sectionNames: [String]
  /// Non-nil only for one slice of an oversized section.
  public let chunk: ChunkRef?
  /// Rows this bucket held when planned (the index row's subtitle).
  public let itemCount: Int

  public var isChunk: Bool { chunk != nil }

  public init(sectionNames: [String], chunk: ChunkRef?, itemCount: Int) {
    self.sectionNames = sectionNames
    self.chunk = chunk
    self.itemCount = itemCount
  }
}

// MARK: - AlphabeticBucketPacker

/// Plans how the CarPlay Albums and Artists tabs divide a library across the car's row
/// budget. Pure on counts; no CarPlay import, so it is unit-tested in AmperfyKit.
public enum AlphabeticBucketPacker {
  /// `[]` means FLAT: every row fits one list (`N <= itemBudget` and the section count fits
  /// `sectionBudget`). Otherwise a balanced list of contiguous ranges, each at most
  /// `itemBudget` rows and `sectionBudget` keys, with any section larger than the budget
  /// split into even positional chunks.
  public static func pack(
    sections: [AlphabeticSectionCount],
    itemBudget: Int,
    sectionBudget: Int
  )
    -> [AlphabeticBucket] {
    let budget = max(1, itemBudget)
    let sectionLimit = max(1, sectionBudget)
    let total = sections.reduce(0) { $0 + $1.count }
    if total <= budget, sections.count <= sectionLimit { return [] }

    let atBudget = nextFit(
      sections: sections,
      threshold: budget,
      itemBudget: budget,
      sectionBudget: sectionLimit
    )
    let bucketCount = atBudget.count
    guard bucketCount > 0 else { return atBudget }
    // Balance: the smallest threshold that still yields the same number of ranges is the
    // most even split. Every bucket holds at most `budget` rows, so ceil(total / count)
    // never exceeds `budget` and the loop always terminates at `budget` at the latest.
    let lowest = max(1, (total + bucketCount - 1) / bucketCount)
    guard lowest < budget else { return atBudget }
    for threshold in lowest ..< budget {
      let candidate = nextFit(
        sections: sections,
        threshold: threshold,
        itemBudget: budget,
        sectionBudget: sectionLimit
      )
      if candidate.count == bucketCount { return candidate }
    }
    return atBudget
  }

  /// Next-fit over the sections in order: close the open bucket when the next section would
  /// push it past `threshold` rows or `sectionBudget` keys; a section larger than
  /// `itemBudget` stands alone as even chunks.
  static func nextFit(
    sections: [AlphabeticSectionCount],
    threshold: Int,
    itemBudget: Int,
    sectionBudget: Int
  )
    -> [AlphabeticBucket] {
    let budget = max(1, itemBudget)
    let sectionLimit = max(1, sectionBudget)
    let limit = max(1, threshold)
    var buckets = [AlphabeticBucket]()
    var openNames = [String]()
    var openCount = 0

    func close() {
      guard !openNames.isEmpty else { return }
      buckets.append(AlphabeticBucket(sectionNames: openNames, chunk: nil, itemCount: openCount))
      openNames = []
      openCount = 0
    }

    for section in sections {
      if section.count > budget {
        close()
        let chunks = (section.count + budget - 1) / budget
        let base = section.count / chunks
        let extra = section.count % chunks
        for index in 0 ..< chunks {
          buckets.append(AlphabeticBucket(
            sectionNames: [section.name],
            chunk: AlphabeticBucket.ChunkRef(index: index, count: chunks),
            itemCount: base + (index < extra ? 1 : 0)
          ))
        }
        continue
      }
      if !openNames.isEmpty,
         openCount + section.count > limit || openNames.count >= sectionLimit {
        close()
      }
      openNames.append(section.name)
      openCount += section.count
    }
    close()
    return buckets
  }

  /// The `index`-th slice of a section that now holds `count` rows, split as evenly as
  /// possible into the `chunks` planned for it. nil when the index is past the plan or the
  /// section is empty. A slice can be empty or larger than the budget after the library
  /// moved; the caller pages the latter.
  public static func chunkRange(count: Int, chunks: Int, index: Int) -> Range<Int>? {
    guard chunks > 0, count > 0, index >= 0, index < chunks else { return nil }
    let base = count / chunks
    let extra = count % chunks
    let start = index * base + min(index, extra)
    let size = base + (index < extra ? 1 : 0)
    return start ..< (start + size)
  }

  /// In-place paging for a list that still cannot fit: `budget - 1` content rows per page
  /// plus one navigation row. `page` is clamped, so a stale page number is never out of
  /// range.
  public static func pageBounds(
    rowCount: Int,
    budget: Int,
    page: Int
  )
    -> (range: Range<Int>, page: Int, pageCount: Int) {
    let rows = max(0, rowCount)
    let limit = max(2, budget)
    if rows <= limit { return (0 ..< rows, 0, 1) }
    let pageSize = limit - 1
    let pageCount = (rows + pageSize - 1) / pageSize
    let clamped = min(max(0, page), pageCount - 1)
    let start = clamped * pageSize
    let end = min(start + pageSize, rows)
    return (start ..< end, clamped, pageCount)
  }

  /// The label character for a section key: the three special keys (`?` symbol-led, `&`
  /// non-Latin, `#` digits) all read as `#` in a range label. They stay separate sections
  /// with their own one-character index titles inside every list.
  public static func displayKey(_ sectionName: String) -> String {
    let key = String(sectionName.prefix(1))
    switch key {
    case "?", "&", "#": return "#"
    default: return key
    }
  }

  /// The index row text: `"# - F"`, `"M"`, or `"S (2 of 3)"` for a chunk.
  public static func label(for bucket: AlphabeticBucket) -> String {
    guard let first = bucket.sectionNames.first else { return "" }
    let firstKey = displayKey(first)
    if let chunk = bucket.chunk {
      return "\(firstKey) (\(chunk.index + 1) of \(chunk.count))"
    }
    let lastKey = displayKey(bucket.sectionNames.last ?? first)
    return firstKey == lastKey ? firstKey : "\(firstKey) - \(lastKey)"
  }
}

// MARK: - CarPlayLimits

/// Every row and section limit a CarPlay list is built against, in one place (design-system
/// audit Wave 1). Overflow bugs recurred (BUG-060, BUG-061, BUG-337) because each builder
/// carried its own clamp. Pure on what the head unit reports; no CarPlay import.
public struct CarPlayLimits: Sendable, Equatable {
  /// Browse lists (the Albums, Artists and Playlists tabs and every pushed range list) never
  /// show more rows than this, whatever the car reports: the BUG-337 symptom is a car that
  /// reports more and draws about 24. Lift rule in `CarPlaySceneDelegate.carPlayBrowseItemBudget`.
  public static let browseCeiling = 24

  /// `CPListTemplate.maximumItemCount` as the car reports it.
  public let reportedItems: Int
  /// `CPListTemplate.maximumSectionCount` as the car reports it.
  public let reportedSections: Int

  public init(reportedItems: Int, reportedSections: Int) {
    self.reportedItems = reportedItems
    self.reportedSections = reportedSections
  }

  /// A report under 4 is treated as unreported (some runtimes answer 0 before a head unit
  /// has connected) and falls back to the browse ceiling.
  private var trustedItems: Int { reportedItems >= 4 ? reportedItems : Self.browseCeiling }

  /// Rows in a browse list, paging row included. Never under 2, so one content row always
  /// sits beside the paging row.
  public var browseItems: Int { max(2, min(trustedItems, Self.browseCeiling)) }

  /// Sections in any list.
  public var sections: Int { max(1, reportedSections) }

  /// Content rows in a leaf list (album tracks, All Songs, playlist songs, the queue) after
  /// `reserved` action rows such as Shuffle, within our own `carPlayMaxElements` ceiling.
  public func leafItems(reserved: Int) -> Int {
    max(0, min(LibraryStorage.carPlayMaxElements, trustedItems - reserved))
  }
}

extension Dictionary where Value: Equatable {
  public func findKey(forValue val: Value) -> Key? {
    first(where: { $1 == val })?.key
  }
}

extension Array {
  public func object(at: Int) -> Element? {
    at < count ? self[at] : nil
  }

  public func chunked(intoSubarrayCount chunkCount: Int) -> [[Element]] {
    let chuckSize = Int(ceil(Float(count) / Float(chunkCount)))
    return chunked(intoSubarraySize: chuckSize)
  }

  public func chunked(intoSubarraySize size: Int) -> [[Element]] {
    guard count > 0 else { return [[Element]]() }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0 ..< Swift.min($0 + size, count)])
    }
  }

  /// Picks `n` random elements (partial Fisher-Yates shuffle approach)
  public subscript(randomPick pickCount: Int) -> [Element] {
    var copy = self
    let n = Swift.min(pickCount, count)
    for i in stride(from: count - 1, to: count - n - 1, by: -1) {
      copy.swapAt(i, Int(arc4random_uniform(UInt32(i + 1))))
    }
    return Array(copy.suffix(n))
  }

  public func prefix(upToAsArray: Int) -> [Element] {
    Array(prefix(upToAsArray))
  }
}

extension UIColor {
  public convenience init(hue: CGFloat, saturation: CGFloat, lightness: CGFloat, alpha: CGFloat) {
    precondition(
      0 ... 1 ~= hue &&
        0 ... 1 ~= saturation &&
        0 ... 1 ~= lightness &&
        0 ... 1 ~= alpha,
      "input range is out of range 0...1"
    )

    // from HSL TO HSB
    var newSaturation: CGFloat = 0.0
    let brightness = lightness + saturation * min(lightness, 1 - lightness)
    if brightness == 0 {
      newSaturation = 0.0
    } else {
      newSaturation = 2 * (1 - lightness / brightness)
    }
    self.init(hue: hue, saturation: newSaturation, brightness: brightness, alpha: alpha)
  }

  public func getHue(
    _ hue: UnsafeMutablePointer<CGFloat>?,
    saturation targetSaturation: UnsafeMutablePointer<CGFloat>?,
    lightness targetLightness: UnsafeMutablePointer<CGFloat>?,
    alpha targetAlpha: UnsafeMutablePointer<CGFloat>?
  )
    -> Bool {
    var saturation, brightness, alpha: CGFloat
    (saturation, brightness, alpha) = (0.0, 0.0, 0.0)
    getHue(hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    // from HSB TO HSL
    var newSaturation: CGFloat = 0.0
    let lightness = brightness * (1 - saturation / 2)
    if lightness == 0 || lightness == 1 {
      newSaturation = 0.0
    } else {
      newSaturation = (brightness - lightness) / min(lightness, 1 - lightness)
    }

    targetSaturation?.pointee = newSaturation
    targetLightness?.pointee = lightness
    targetAlpha?.pointee = alpha
    return true
  }

  public func getWithLightness(of: CGFloat) -> UIColor {
    precondition(0 ... 1 ~= of, "input range is out of range 0...1")
    var hue, saturation, lightness, alpha: CGFloat
    (hue, saturation, lightness, alpha) = (0.0, 0.0, 0.0, 0.0)
    _ = getHue(&hue, saturation: &saturation, lightness: &lightness, alpha: &alpha)
    return UIColor(hue: hue, saturation: saturation, lightness: of, alpha: alpha)
  }

  public static var gold: UIColor {
    UIColor(displayP3Red: 241 / 255, green: 194 / 255, blue: 66 / 255, alpha: 1.0)
  }

  // cassette Patch 016: redirect the legacy *Color helpers to the Cassette
  // tokens defined in CassetteTheme. These helpers are referenced in dozens
  // of places, so this single redirection sweeps the rest of the surface.
  public static var labelColor: UIColor {
    UIColor.cassette(.textPrimary)
  }

  public static var redHeart: UIColor {
    .red.withAlphaComponent(0.8)
  }

  public static var fillColor: UIColor {
    UIColor.cassette(.surfaceRaised)
  }

  public static var secondaryLabelColor: UIColor {
    UIColor.cassette(.textSecondary)
  }

  public static var backgroundColor: UIColor {
    UIColor.cassette(.surfaceBase)
  }
}

extension UIActivityIndicatorView {
  public static var defaultStyle: Style {
    if #available(iOS 13.0, *) {
      return .medium
    } else {
      return .gray
    }
  }
}

extension NSObject {
  public class var typeName: String {
    String(describing: self)
  }
}

extension NSData {
  public var sizeInByte: Int64 {
    Int64(length)
  }
}

extension Data {
  public static func fetch(fromUrlString urlString: String) -> Data? {
    var data: Data?
    guard let url = URL(string: urlString) else {
      return nil
    }
    do {
      let dataFromURL = try Data(contentsOf: url)
      data = dataFromURL
    } catch {}
    return data
  }

  public var sizeInByte: Int64 {
    Int64(count)
  }

  public func createLocalUrl(fileName: String? = nil) -> URL {
    let tempDirectoryURL = NSURL.fileURL(withPath: NSTemporaryDirectory(), isDirectory: true)
    let url = tempDirectoryURL.appendingPathComponent(fileName ?? UUID().uuidString)
    try! write(to: url, options: Data.WritingOptions.atomic)
    return url
  }

  public var html2AttributedString: NSAttributedString? {
    try? NSAttributedString(
      data: self,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil
    )
  }

  public var html2String: String { html2AttributedString?.string.html2String ?? "" }
}

extension Date {
  public var asIso8601String: String {
    let dateFormatter = ISO8601DateFormatter()
    return dateFormatter.string(from: self)
  }

  public var asShortDayMonthString: String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "d. MMMM"
    dateFormatter.timeZone = NSTimeZone(name: "UTC")! as TimeZone
    return dateFormatter.string(from: self)
  }

  public var asShortHrMinString: String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .none
    dateFormatter.timeStyle = .short
    return dateFormatter.string(from: self)
  }
}

extension URLComponents {
  public mutating func addQueryItem(name: String, value: Int) {
    addQueryItem(name: name, value: String(value))
  }

  public mutating func addQueryItem(name: String, value: String) {
    let queryItem = URLQueryItem(name: name, value: value)
    var queryItems = queryItems ?? [URLQueryItem]()
    queryItems.append(queryItem)
    self.queryItems = queryItems
  }
}

extension Array {
  public func element(at index: Int) -> Element? {
    index < count ? self[index] : nil
  }
}

extension Array where Element: Equatable {
  public func allIndices(of element: Element) -> [Int] {
    enumerated().filter {
      $0.element == element
    }.map {
      $0.offset
    }
  }
}

extension Array where Element == String {
  public func sortAlphabeticallyAscending() -> [String] {
    sorted { $0.localizedStandardCompare($1) == ComparisonResult.orderedAscending }
  }

  public func sortAlphabeticallyDescending() -> [String] {
    sorted { $0.localizedStandardCompare($1) == ComparisonResult.orderedDescending }
  }
}

extension UIView {
  public func setGradientBackground(colorTop: UIColor, colorBottom: UIColor) {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [colorBottom.cgColor, colorTop.cgColor]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
    gradientLayer.locations = [0, 1]
    gradientLayer.frame = bounds
    layer.insertSublayer(gradientLayer, at: 0)
  }

  public var screenshot: UIImage? {
    UIGraphicsBeginImageContextWithOptions(layer.frame.size, false, 0)
    defer {
      UIGraphicsEndImageContext()
    }
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    layer.render(in: context)
    return UIGraphicsGetImageFromCurrentImageContext()
  }
}

extension UIAlertAction {
  public convenience init(
    title: String?,
    image: UIImage,
    style: Style,
    handler: ((UIAlertAction) -> ())? = nil
  ) {
    self.init(title: title, style: style, handler: handler)
    self.image = image
  }

  public var image: UIImage {
    get { value(forKey: "image") as? UIImage ?? UIImage() }
    set(image) { setValue(image, forKey: "image") }
  }
}

extension UIImage {
  public func invertedImage() -> UIImage {
    guard let cgImage = cgImage else { return UIImage() }
    let ciImage = CoreImage.CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIColorInvert") else { return UIImage() }
    filter.setDefaults()
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    let context = CIContext(options: nil)
    guard let outputImage = filter.outputImage else { return UIImage() }
    guard let outputImageCopy = context.createCGImage(outputImage, from: outputImage.extent)
    else { return UIImage() }
    return UIImage(cgImage: outputImageCopy, scale: scale, orientation: .up)
  }
}

extension UIDevice {
  public var totalDiskCapacityInByte: Int64? {
    let fileURL = URL(fileURLWithPath: "/")
    guard let values = try? fileURL.resourceValues(forKeys: [.volumeTotalCapacityKey]),
          let capacity = values.volumeTotalCapacity else { return nil }
    return Int64(capacity)
  }

  public var availableDiskCapacityInByte: Int64? {
    let fileURL = URL(fileURLWithPath: "/")
    guard let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
          let capacity = values.volumeAvailableCapacity else { return nil }
    return Int64(capacity)
  }
}
