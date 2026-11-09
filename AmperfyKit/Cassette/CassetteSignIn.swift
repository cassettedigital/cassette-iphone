//
//  CassetteSignIn.swift
//  AmperfyKit
//
//  Cassette fork (security design rule 3, BUG-878, the iPhone half of BUG-859): a sign-in only
//  lands in the app that asked for it.
//
//  Each sign-in starts with a fresh one-time code and a fresh X25519 key, both sent out on the
//  pairing page's address and kept only for the sheet that opened it. What comes back to
//  `cassette://auth/callback` is taken only when its code is the one this sign-in sent. A sealed
//  sign-in is opened with this sign-in's key, the same way the computer app (`pairing.rs`
//  open_sealed) and Android (`CassetteSeal.open`) do, against the cloud's `lib/pairing-seal.ts`;
//  change one, change all four.
//
//  Sealed = base64url( cloud public key (32) | nonce (12) | AES-256-GCM ciphertext and tag ). The
//  key is HKDF-SHA256 over the X25519 shared secret, salted with both public keys (cloud's first),
//  info "cassette-pairing-v1", no associated data.
//
//  Until the cloud seals for phones too, it sends the sign-in plain beside the code; that is taken
//  only with the matching code. Once the cloud seals for phones, `answer(to:)`'s plain branch goes.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import CryptoKit
import Foundation

// MARK: - CassetteSignInRequest

/// One sign-in through the pairing page: its code, its key, and what to make of the answer.
public struct CassetteSignInRequest: Sendable {
  public static let callbackScheme = "cassette"
  public static let redirectURI = "cassette://auth/callback"
  public static let client = "cassette-ios"
  private static let pairingPage = "https://cassette.digital/auth/player"

  /// The one-time code, as the cloud keeps it (`pairingState`): 43 characters of base64url.
  public let state: String
  private let privateKey: Curve25519.KeyAgreement.PrivateKey

  /// The public half as it rides the address (`pairingKey`): 43 characters of base64url.
  public var publicKeyText: String {
    CassetteSeal.base64url(privateKey.publicKey.rawRepresentation)
  }

  /// A fresh code and key.
  public init() {
    self.init(
      state: CassetteSeal.base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }),
      privateKey: Curve25519.KeyAgreement.PrivateKey()
    )
  }

  init(state: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
    self.state = state
    self.privateKey = privateKey
  }

  /// The pairing page, with where to come back to, which app, this sign-in's code and its key.
  public var pairingURL: URL? {
    let redirect = Self.redirectURI
      .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    return URL(
      string: "\(Self.pairingPage)?redirect_uri=\(redirect)&client=\(Self.client)" +
        "&state=\(state)&key=\(publicKeyText)"
    )
  }

  public enum Answer: Equatable, Sendable {
    /// The sign-in this phone asked for.
    case signIn(token: String)
    /// Cancel on the pairing page (BUG-642): as quiet as the sheet's own Cancel.
    case cancelled
    /// Not an answer to this sign-in (no code, or another one): dropped, nothing changes.
    case notOurs
    /// Ours, but nothing usable in it (a seal this key can't open, or no sign-in at all).
    case failed
  }

  /// What came back to `cassette://auth/callback`.
  public func answer(to url: URL?) -> Answer {
    guard let url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return .failed }
    func value(_ name: String) -> String? {
      items.first(where: { $0.name == name })?.value
    }
    if value("error") == "cancelled" { return .cancelled }
    guard CassetteSeal.sameCode(state, value("state")) else { return .notOurs }
    if let sealed = value("sealed"), !sealed.isEmpty {
      guard let token = CassetteSeal.open(sealed, privateKey: privateKey) else { return .failed }
      return .signIn(token: token)
    }
    if let token = value("token"), !token.isEmpty { return .signIn(token: token) }
    return .failed
  }
}

// MARK: - CassetteSeal

public enum CassetteSeal {
  private static let info = Data("cassette-pairing-v1".utf8)
  private static let keyBytes = 32
  private static let nonceBytes = 12
  private static let tagBytes = 16

  /// The sign-in inside `sealed`, or nil when this key can't open it (not ours, damaged, empty).
  public static func open(
    _ sealed: String,
    privateKey: Curve25519.KeyAgreement.PrivateKey
  )
    -> String? {
    open(sealed, privateKey: privateKey, publicKey: privateKey.publicKey.rawRepresentation)
  }

  /// As above, with the public half given apart (both halves salt the key, so the wrong one fails).
  static func open(
    _ sealed: String,
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    publicKey: Data
  )
    -> String? {
    guard let raw = data(base64url: sealed), raw.count >= keyBytes + nonceBytes + tagBytes
    else { return nil }
    let cloud = Data(raw.prefix(keyBytes))
    let nonceData = Data(raw.dropFirst(keyBytes).prefix(nonceBytes))
    let body = Data(raw.dropFirst(keyBytes + nonceBytes))
    guard let cloudKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: cloud),
          let shared = try? privateKey.sharedSecretFromKeyAgreement(with: cloudKey),
          let nonce = try? AES.GCM.Nonce(data: nonceData),
          let box = try? AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: body.prefix(body.count - tagBytes),
            tag: body.suffix(tagBytes)
          )
    else { return nil }
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: cloud + publicKey,
      sharedInfo: info,
      outputByteCount: 32
    )
    guard let plain = try? AES.GCM.open(box, using: key),
          let token = String(data: plain, encoding: .utf8), !token.isEmpty
    else { return nil }
    return token
  }

  /// Whether two codes are the same, in time that doesn't depend on where they differ.
  public static func sameCode(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
  }

  /// base64url without padding.
  public static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// base64url without padding, back to bytes; nil for anything outside that alphabet.
  public static func data(base64url text: String) -> Data? {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    guard text.allSatisfy({ allowed.contains($0) }), text.count % 4 != 1 else { return nil }
    let standard = text
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: padded)
  }
}
