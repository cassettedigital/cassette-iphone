//
//  CassetteSignInTest.swift
//  AmperfyKitTests
//
//  Cassette fork (security design rule 3, BUG-878): the iPhone opens what the cloud seals, and
//  takes only the answer to the sign-in it started. Both vectors were sealed by the cloud's own
//  `sealToken` (apps/cassette/src/lib/pairing-seal.ts, run with tsx on 2026-11-09) to throwaway
//  keys made for a test; the sign-ins inside are made up. The second is Android's
//  (`CassetteSealTest`), so the two phones are checked against the same seals.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import CryptoKit
import XCTest

class CassetteSignInTest: XCTestCase {
  // Sealed for this test.
  let privateText = "CC_rk8qUfCSPlPKLBiqLTNUlLtTa_0rR-S2yVNHg9nA"
  let publicText = "GOkbrYqAkTq14cdmOmStN80p3F9mDh7cViJCphJLGFM"
  let token = "cassette-test-token-for-the-iphone-not-a-real-sign-in"
  let sealed =
    "xtEEYgysoVJu3Nq0eTK-m1bMpNA6CHl3KC_mJrEhGxrL0vkYZEMAvkY7FuDeRW_YgfQMKB4qm2glfRZc3AnsPi_R9FiqMRbXFK4bw6EsLbFW_mPd-aZkeK2KrxwHCc3UnMPHy0Yz5cJxia1trkVr5pY"

  // Android's (CassetteSealTest).
  let androidPrivateText = "SKtczQc8xBPPFnFn-5FkHjKLWtDbPftpzbSZnbodPVM"
  let androidPublicText = "oCYRhX9Z3k0SvXxq_5MnsT8_ZMhK1rf6Aesl4xoWkjA"
  let androidSealed =
    "CBKNEkVkIK6vPP9MMuGC_l_Q-56uIygJohuwDsP3WE_i4Avbt65OCvN-QjUyYbrzxoS0Ay329CO5_1Epc7dD6BNOiSR4m8VpKO-e7Xj-Ge2bqZ85GuQfzgPlStDOTVA14iQ"

  let code = "Zm9yLXRoaXMtdGVzdC1vbmx5LWEtbWFkZS11cC1jb2Rl"

  func key(_ text: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: XCTUnwrap(CassetteSeal.data(base64url: text))
    )
  }

  func request() throws -> CassetteSignInRequest {
    try CassetteSignInRequest(state: code, privateKey: key(privateText))
  }

  func callback(_ query: String) -> URL {
    URL(string: "cassette://auth/callback?\(query)")!
  }

  // MARK: - The seal

  func testOpensWhatTheCloudSealed() throws {
    let mine = try key(privateText)
    XCTAssertEqual(CassetteSeal.base64url(mine.publicKey.rawRepresentation), publicText)
    XCTAssertEqual(CassetteSeal.open(sealed, privateKey: mine), token)
  }

  func testOpensAndroidsVectorToo() throws {
    let theirs = try key(androidPrivateText)
    XCTAssertEqual(CassetteSeal.base64url(theirs.publicKey.rawRepresentation), androidPublicText)
    XCTAssertEqual(
      CassetteSeal.open(androidSealed, privateKey: theirs),
      "cassette-test-token-not-a-real-sign-in"
    )
  }

  func testAnotherKeyCantOpenIt() throws {
    let other = Curve25519.KeyAgreement.PrivateKey()
    XCTAssertNil(CassetteSeal.open(sealed, privateKey: other))
    // the right private key with the wrong public half changes the key too (both halves salt it)
    XCTAssertNil(CassetteSeal.open(
      sealed,
      privateKey: try key(privateText),
      publicKey: other.publicKey.rawRepresentation
    ))
  }

  func testADamagedOrShortSealOpensToNothing() throws {
    let mine = try key(privateText)
    var chars = Array(sealed)
    chars[60] = chars[60] == "A" ? "B" : "A"
    XCTAssertNil(CassetteSeal.open(String(chars), privateKey: mine))
    XCTAssertNil(CassetteSeal.open(String(sealed.prefix(70)), privateKey: mine))
    XCTAssertNil(CassetteSeal.open("", privateKey: mine))
    XCTAssertNil(CassetteSeal.open("not base64 at all!", privateKey: mine))
    // the standard alphabet's + and / are not base64url
    XCTAssertNil(CassetteSeal.open(
      sealed.replacingOccurrences(of: "-", with: "+"),
      privateKey: mine
    ))
  }

  func testCodesCompare() {
    XCTAssertTrue(CassetteSeal.sameCode("abc", "abc"))
    XCTAssertFalse(CassetteSeal.sameCode("abc", "abd"))
    XCTAssertFalse(CassetteSeal.sameCode("abc", "abcd"))
    XCTAssertFalse(CassetteSeal.sameCode("abc", nil))
    XCTAssertFalse(CassetteSeal.sameCode(nil, nil))
  }

  func testBase64urlRoundTrips() {
    var generator = SystemRandomNumberGenerator()
    for n in 0 ... 70 {
      let bytes = Data((0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
      let text = CassetteSeal.base64url(bytes)
      XCTAssertFalse(text.contains("="))
      XCTAssertFalse(text.contains("+"))
      XCTAssertFalse(text.contains("/"))
      XCTAssertEqual(CassetteSeal.data(base64url: text), bytes)
    }
  }

  // MARK: - The sign-in

  func testCodeAndKeyAreShapedAsTheCloudAccepts() throws {
    // pairingKey: /^[A-Za-z0-9_-]{43}$/ ; pairingState: /^[A-Za-z0-9_-]{16,128}$/
    let fresh = CassetteSignInRequest()
    let key = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{43}$")
    let state = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{16,128}$")
    func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
      re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    XCTAssertTrue(matches(key, fresh.publicKeyText))
    XCTAssertTrue(matches(state, fresh.state))
    XCTAssertEqual(fresh.state.count, 43)
    let another = CassetteSignInRequest()
    XCTAssertNotEqual(fresh.state, another.state)
    XCTAssertNotEqual(fresh.publicKeyText, another.publicKeyText)
  }

  func testThePairingAddressCarriesTheCodeAndKey() throws {
    let url = try XCTUnwrap(try request().pairingURL)
    XCTAssertEqual(url.host, "cassette.digital")
    XCTAssertEqual(url.path, "/auth/player")
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
    XCTAssertEqual(value("redirect_uri"), "cassette://auth/callback")
    XCTAssertEqual(value("client"), "cassette-ios")
    XCTAssertEqual(value("state"), code)
    XCTAssertEqual(value("key"), publicText)
  }

  func testTakesTheSealedSignInWithItsCode() throws {
    XCTAssertEqual(
      try request().answer(to: callback("sealed=\(sealed)&state=\(code)")),
      .signIn(token: token)
    )
  }

  func testTakesAPlainSignInWithItsCodeUntilTheCloudSealsForPhones() throws {
    XCTAssertEqual(
      try request().answer(to: callback("token=t%2Fk&state=\(code)")),
      .signIn(token: "t/k")
    )
  }

  func testDropsAnAnswerWithoutThisCode() throws {
    let r = try request()
    XCTAssertEqual(r.answer(to: callback("token=planted")), .notOurs)
    XCTAssertEqual(r.answer(to: callback("token=planted&state=someone-elses-code-xyz")), .notOurs)
    XCTAssertEqual(r.answer(to: callback("sealed=\(sealed)")), .notOurs)
    XCTAssertEqual(r.answer(to: callback("sealed=\(sealed)&state=\(code)x")), .notOurs)
  }

  func testASealThisKeyCantOpenFailsEvenWithThePlainTokenBesideIt() throws {
    // a sealed answer is never quietly swapped for a plain one
    XCTAssertEqual(
      try request().answer(to: callback("sealed=\(androidSealed)&token=plain&state=\(code)")),
      .failed
    )
  }

  func testCancelAndEmptyAnswers() throws {
    let r = try request()
    XCTAssertEqual(r.answer(to: callback("error=cancelled")), .cancelled)
    XCTAssertEqual(r.answer(to: callback("state=\(code)")), .failed)
    XCTAssertEqual(r.answer(to: callback("token=&state=\(code)")), .failed)
    XCTAssertEqual(r.answer(to: nil), .failed)
  }

  // MARK: This phone's id and label (BUG-459)

  func testDeviceIdIsNeverPinnedToTheStandIn() {
    let cache = DeviceIdentityCache()
    // Before the first unlock after a restart the system withholds the id.
    XCTAssertEqual(cache.deviceId { nil }, "unknown-device")
    XCTAssertEqual(cache.deviceId { "" }, "unknown-device")
    // The stand-in was not kept: the real id is used from the first call that has it.
    XCTAssertEqual(cache.deviceId { "VENDOR-ONE" }, "VENDOR-ONE")
    // Then it never changes, whatever a later read says.
    XCTAssertEqual(cache.deviceId { nil }, "VENDOR-ONE")
    XCTAssertEqual(cache.deviceId { "VENDOR-TWO" }, "VENDOR-ONE")
    cache.keep(id: "VENDOR-THREE", label: nil)
    XCTAssertEqual(cache.deviceId { nil }, "VENDOR-ONE")
  }

  func testKeptDeviceIdentityIsNotReadAgain() {
    let cache = DeviceIdentityCache()
    cache.keep(id: nil, label: "") // nothing real: nothing kept
    XCTAssertEqual(cache.deviceId { nil }, "unknown-device")
    XCTAssertEqual(cache.deviceLabel { nil }, "iPhone")
    cache.keep(id: "VENDOR-ONE", label: "Michael's iPhone")
    XCTAssertEqual(cache.deviceId { XCTFail("read again"); return nil }, "VENDOR-ONE")
    XCTAssertEqual(cache.deviceLabel { XCTFail("read again"); return nil }, "Michael's iPhone")
  }

  /// The id the sync layer sends is the system's own vendor id, the same string, from the main
  /// thread, from another thread before anything was kept, and from another thread after.
  @MainActor
  func testDeviceIdIsTheVendorIdFromEveryThread() async throws {
    let expected = try XCTUnwrap(UIDevice.current.identifierForVendor?.uuidString)
    let expectedName = UIDevice.current.name
    let before = await Task.detached { CassetteSyncAPI.readDeviceOnMainThread() }.value
    XCTAssertEqual(before?.id, expected)
    XCTAssertEqual(before?.label, expectedName)
    XCTAssertEqual(CassetteSyncAPI.readDeviceOnMainThread()?.id, expected)
    let unprimed = await Task.detached { CassetteSyncAPI.deviceId }.value
    XCTAssertEqual(unprimed, expected)
    CassetteSyncAPI.primeDeviceIdentity()
    XCTAssertEqual(CassetteSyncAPI.deviceId, expected)
    let primed = await Task.detached { CassetteSyncAPI.deviceId }.value
    XCTAssertEqual(primed, expected)
    let label = await Task.detached { CassetteSyncAPI.deviceLabel }.value
    XCTAssertEqual(label, expectedName)
  }
}
