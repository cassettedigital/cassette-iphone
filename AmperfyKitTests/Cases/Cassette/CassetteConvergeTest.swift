//
//  CassetteConvergeTest.swift
//  AmperfyKitTests
//
//  Cassette fork (BUG-078): Resync Library asks the computer to read its music folder again
//  through the hub's encrypted Wi-Fi gateway, at the address the phone plays from, signed in
//  the way every Subsonic call is. The hub half is apps/cassette-player/sidecar/lan-tls.go
//  (lanConvergeDoor), whose test sends the same shape of ask.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import XCTest

class CassetteConvergeTest: XCTestCase {
  func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
  }

  // MARK: - The address

  func testAsksTheAddressInUseWithItsHostAndPort() throws {
    let url = try XCTUnwrap(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://michaels-macbook-pro.local:4533",
      username: "phone",
      password: "secret",
      salt: "abc123"
    ))
    let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(parts.scheme, "https")
    XCTAssertEqual(parts.host, "michaels-macbook-pro.local")
    XCTAssertEqual(parts.port, 4533) // the gateway's port, never the hub's own
    XCTAssertEqual(parts.path, "/api/library/converge")
  }

  func testCarriesTheSubsonicSignIn() throws {
    let url = try XCTUnwrap(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://192.168.1.20:4533",
      username: "phone",
      password: "secret",
      salt: "abc123"
    ))
    let q = query(url)
    XCTAssertEqual(q["u"], "phone")
    XCTAssertEqual(q["s"], "abc123")
    // md5("secret" + "abc123"), as SubsonicServerApi.generateAuthenticationToken makes it.
    XCTAssertEqual(q["t"], StringHasher.md5Hex(dataString: "secretabc123"))
    XCTAssertEqual(q["t"]?.count, 32)
    XCTAssertEqual(q["v"], "1.16.1")
    XCTAssertEqual(q["c"], "Amperfy")
    XCTAssertNil(q["p"], "the password itself never goes on the address")
  }

  func testAFreshSaltEachTime() throws {
    let a = try XCTUnwrap(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://192.168.1.20:4533", username: "phone", password: "secret"
    ))
    let b = try XCTUnwrap(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://192.168.1.20:4533", username: "phone", password: "secret"
    ))
    XCTAssertEqual(query(a)["s"]?.count, 16)
    XCTAssertNotEqual(query(a)["s"], query(b)["s"])
    XCTAssertNotEqual(query(a)["t"], query(b)["t"])
  }

  func testPlainHttpDoesNotAsk() {
    // No key pin yet: the gateway would refuse it (403), so the phone doesn't send it.
    XCTAssertNil(CassetteSyncAPI.convergeURL(
      activeServerUrl: "http://192.168.1.20:4533", username: "phone", password: "secret"
    ))
  }

  func testNoAddressOrSignInDoesNotAsk() {
    XCTAssertNil(CassetteSyncAPI.convergeURL(
      activeServerUrl: "", username: "phone", password: "secret"
    ))
    XCTAssertNil(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://192.168.1.20:4533", username: "", password: "secret"
    ))
    XCTAssertNil(CassetteSyncAPI.convergeURL(
      activeServerUrl: "https://192.168.1.20:4533", username: "phone", password: ""
    ))
  }

  func testPlainHttpCredentialsGiveUnavailableWithoutCalling() async {
    let credentials = LoginCredentials(
      serverUrl: "http://192.168.1.20:4533", username: "phone", password: "secret"
    )
    let result = await CassetteSyncAPI.shared.convergeOnPlayer(credentials: credentials)
    XCTAssertEqual(result, .unavailable)
    let none = await CassetteSyncAPI.shared.convergeOnPlayer(credentials: nil)
    XCTAssertEqual(none, .unavailable)
  }

  // MARK: - The answer

  func testReadsTheGatewaysAnswer() {
    let done = Data(#"{"ok":true,"converged":true,"albums":3}"#.utf8)
    let late = Data(#"{"ok":true,"converged":false,"timeout":true}"#.utf8)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 200, body: done), .converged)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 200, body: late), .timeout)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 401, body: Data()), .unavailable)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 403, body: Data()), .unavailable)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 404, body: Data()), .unavailable)
    XCTAssertEqual(CassetteSyncAPI.convergeResult(status: 502, body: Data()), .unreachable)
  }
}
