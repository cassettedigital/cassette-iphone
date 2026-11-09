//
//  CassetteTokenReauth.swift
//  Amperfy
//
//  Cassette fork — Layer 3 Phase 3.1 (debug helper).
//
//  Re-runs the `/auth/player` web-auth flow purely to mint and persist a fresh
//  Cassette bearer token for an account that is ALREADY logged in, so the sync
//  layer (/api/sync/*) can authenticate. Unlike LoginVC's flow it does NOT
//  create or modify an Amperfy account — it only hands the caller the token to
//  persist. Used by the DEBUG Developer settings screen ("Re-link Cassette").
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
import AuthenticationServices
import UIKit

// MARK: - CassetteTokenReauth

final class CassetteTokenReauth: NSObject {
  private var webAuthSession: ASWebAuthenticationSession?
  // Keep ourselves alive for the duration of the async web-auth flow.
  private var retainSelf: CassetteTokenReauth?

  /// Presents the Cassette sign-in sheet and returns the freshly minted bearer
  /// token (or nil on cancel/failure). The caller persists it and kicks off a
  /// sync. Verbose-but-temporary `print` logging mirrors the rest of Phase 3.1.
  func start(completion: @escaping (String?) -> ()) {
    // A fresh one-time code and key for this sheet only (BUG-878), as LoginVC's sign-in.
    let request = CassetteSignInRequest()
    guard let authURL = request.pairingURL else {
      print("Cassette re-link: bad auth URL")
      completion(nil)
      return
    }

    retainSelf = self
    print("Cassette re-link: starting /auth/player web-auth")

    let session = ASWebAuthenticationSession(
      url: authURL,
      callbackURLScheme: CassetteSignInRequest.callbackScheme
    ) { [weak self] callbackURL, error in
      defer {
        self?.webAuthSession = nil
        self?.retainSelf = nil
      }
      if let error {
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
          print("Cassette re-link: cancelled by user")
        } else {
          print("Cassette re-link: failed - \(error.localizedDescription)")
        }
        completion(nil)
        return
      }
      guard case let .signIn(token) = request.answer(to: callbackURL) else {
        print("Cassette re-link: no sign-in for this request in the callback")
        completion(nil)
        return
      }
      print("Cassette re-link: received token (len=\(token.count))")
      completion(token)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    webAuthSession = session
    session.start()
  }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension CassetteTokenReauth: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first ?? ASPresentationAnchor()
  }
}
