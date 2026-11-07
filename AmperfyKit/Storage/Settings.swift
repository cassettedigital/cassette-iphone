//
//  Settings.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

import Security
import UIKit

// MARK: - AppSettings

public struct AppSettings: Sendable, Codable {
  private var _isLibrarySyncInfoReadByUser: Bool = false
  public var isLibrarySyncInfoReadByUser: Bool {
    get { _isLibrarySyncInfoReadByUser }
    set { _isLibrarySyncInfoReadByUser = newValue }
  }

  private var _isLibrarySynced: Bool = false
  public var isLibrarySynced: Bool {
    get { _isLibrarySynced }
    set { _isLibrarySynced = newValue }
  }

  private var _librarySyncVersion: LibrarySyncVersion = .v6
  public var librarySyncVersion: LibrarySyncVersion {
    get { _librarySyncVersion }
    set { _librarySyncVersion = newValue }
  }

  // Cassette (Phase 1, Gap 1): the last device-album-grouping model version the
  // regroup applied. Optional backing so existing installs (whose persisted blob
  // predates this key) still decode cleanly via decodeIfPresent — a non-optional
  // field would fail to decode and silently reset every app setting. Exposed as a
  // plain Int (0 == never applied).
  private var _appliedGroupingModelVersion: Int?
  public var appliedGroupingModelVersion: Int {
    get { _appliedGroupingModelVersion ?? 0 }
    set { _appliedGroupingModelVersion = newValue }
  }
}

// MARK: - UserSettings

public struct UserSettings: Sendable, Codable {
  private var _streamingMaxBitrateWifiPreference: StreamingMaxBitratePreference = .defaultValue
  public var streamingMaxBitrateWifiPreference: StreamingMaxBitratePreference {
    get { _streamingMaxBitrateWifiPreference }
    set { _streamingMaxBitrateWifiPreference = newValue }
  }

  private var _streamingMaxBitrateCellularPreference: StreamingMaxBitratePreference = .defaultValue
  public var streamingMaxBitrateCellularPreference: StreamingMaxBitratePreference {
    get { _streamingMaxBitrateCellularPreference }
    set { _streamingMaxBitrateCellularPreference = newValue }
  }

  private var _streamingFormatWifiPreference: StreamingFormatPreference = .defaultValue
  public var streamingFormatWifiPreference: StreamingFormatPreference {
    get { _streamingFormatWifiPreference }
    set { _streamingFormatWifiPreference = newValue }
  }

  private var _streamingFormatCellularPreference: StreamingFormatPreference = .defaultValue
  public var streamingFormatCellularPreference: StreamingFormatPreference {
    get { _streamingFormatCellularPreference }
    set { _streamingFormatCellularPreference = newValue }
  }

  private var _cacheTranscodingFormatPreference: CacheTranscodingFormatPreference = .defaultValue
  public var cacheTranscodingFormatPreference: CacheTranscodingFormatPreference {
    get { _cacheTranscodingFormatPreference }
    set { _cacheTranscodingFormatPreference = newValue }
  }

  private var _isShowDetailedInfo: Bool = false
  public var isShowDetailedInfo: Bool {
    get { _isShowDetailedInfo }
    set { _isShowDetailedInfo = newValue }
  }

  // cassette §B: toggle culled; song durations show in track lists by default.
  private var _isShowSongDuration: Bool = true
  public var isShowSongDuration: Bool {
    get { _isShowSongDuration }
    set { _isShowSongDuration = newValue }
  }

  private var _isShowAlbumDuration: Bool = false
  public var isShowAlbumDuration: Bool {
    get { _isShowAlbumDuration }
    set { _isShowAlbumDuration = newValue }
  }

  private var _isShowArtistDuration: Bool = false
  public var isShowArtistDuration: Bool {
    get { _isShowArtistDuration }
    set { _isShowArtistDuration = newValue }
  }

  private var _isShowRating: Bool = false
  public var isShowRating: Bool {
    get { _isShowRating }
    set { _isShowRating = newValue }
  }

  private var _isPlayerShuffleButtonEnabled: Bool = true
  public var isPlayerShuffleButtonEnabled: Bool {
    get { _isPlayerShuffleButtonEnabled }
    set { _isPlayerShuffleButtonEnabled = newValue }
  }

  // cassette §B: toggle culled; skip-forward/backward buttons on by default.
  private var _isShowMusicPlayerSkipButtons: Bool = true
  public var isShowMusicPlayerSkipButtons: Bool {
    get { _isShowMusicPlayerSkipButtons }
    set { _isShowMusicPlayerSkipButtons = newValue }
  }

  private var _isLyricsSmoothScrolling: Bool = true
  public var isLyricsSmoothScrolling: Bool {
    get { _isLyricsSmoothScrolling }
    set { _isLyricsSmoothScrolling = newValue }
  }

  // limit in byte
  private var _cacheLimit: Int = 0
  public var cacheLimit: Int {
    get { _cacheLimit }
    set { _cacheLimit = newValue }
  }

  private var _isPlayerLyricsDisplayed: Bool = false
  public var isPlayerLyricsDisplayed: Bool {
    get { _isPlayerLyricsDisplayed }
    set { _isPlayerLyricsDisplayed = newValue }
  }

  private var _isPlayerVisualizerDisplayed: Bool = false
  public var isPlayerVisualizerDisplayed: Bool {
    get { _isPlayerVisualizerDisplayed }
    set { _isPlayerVisualizerDisplayed = newValue }
  }

  private var _selectedVisualizerType: VisualizerType = .defaultValue
  public var selectedVisualizerType: VisualizerType {
    get { _selectedVisualizerType }
    set { _selectedVisualizerType = newValue }
  }

  private var _isOfflineMode: Bool = false
  public var isOfflineMode: Bool {
    get { _isOfflineMode }
    set { _isOfflineMode = newValue }
  }

  public var isOnlineMode: Bool {
    !_isOfflineMode
  }

  private var _isPlaybackStartOnlyOnPlay: Bool = false
  public var isPlaybackStartOnlyOnPlay: Bool {
    get { _isPlaybackStartOnlyOnPlay }
    set { _isPlaybackStartOnlyOnPlay = newValue }
  }

  private var _isPlayerSongPlaybackResumeEnabled: Bool = false
  public var isPlayerSongPlaybackResumeEnabled: Bool {
    get { _isPlayerSongPlaybackResumeEnabled }
    set { _isPlayerSongPlaybackResumeEnabled = newValue }
  }

  private var _isHapticsEnabled: Bool = true
  public var isHapticsEnabled: Bool {
    get { _isHapticsEnabled }
    set { _isHapticsEnabled = newValue }
  }

  private var _isEqualizerEnabled: Bool = false
  public var isEqualizerEnabled: Bool {
    get { _isEqualizerEnabled }
    set { _isEqualizerEnabled = newValue }
  }

  private var _activeEqualizerSetting: EqualizerSetting = .off
  public var activeEqualizerSetting: EqualizerSetting {
    get { _activeEqualizerSetting }
    set { _activeEqualizerSetting = newValue }
  }

  private var _equalizerSettings: [EqualizerSetting] = []
  public var equalizerSettings: [EqualizerSetting] {
    get { _equalizerSettings }
    set { _equalizerSettings = newValue }
  }

  private var _isMiniPlayerAlwaysOnTop: Bool = false
  public var isMiniPlayerAlwaysOnTop: Bool {
    get { _isMiniPlayerAlwaysOnTop }
    set { _isMiniPlayerAlwaysOnTop = newValue }
  }

  private var _playerVolume: Float = 1.0
  public var playerVolume: Float {
    get {
      (_playerVolume >= 0.0 && _playerVolume <= 1.0) ? _playerVolume : 1.0
    }
    set {
      guard newValue >= 0.0, newValue <= 1.0 else { return }
      _playerVolume = newValue
    }
  }

  private var _appearanceMode: UIUserInterfaceStyle = .unspecified
  public var appearanceMode: UIUserInterfaceStyle {
    get { _appearanceMode }
    set { _appearanceMode = newValue }
  }

  private var _screenLockPreventionPreference: ScreenLockPreventionPreference = .defaultValue
  public var screenLockPreventionPreference: ScreenLockPreventionPreference {
    get { _screenLockPreventionPreference }
    set { _screenLockPreventionPreference = newValue }
  }

  private var _playlistsSortSetting: PlaylistSortType = .defaultValue
  /// cassette (One Home): the sort the person picked. nil: never picked, so playlists sort by
  /// the one last played on any device. Optional so settings saved before it still decode.
  private var _playlistsSortPicked: PlaylistSortType?
  public var playlistsSortSetting: PlaylistSortType {
    get {
      if let picked = _playlistsSortPicked { return picked }
      // A sort other than the old default (A-Z) was a pick made before this was kept.
      return _playlistsSortSetting == .name ? .lastPlayed : _playlistsSortSetting
    }
    set {
      _playlistsSortSetting = newValue
      _playlistsSortPicked = newValue
    }
  }

  private var _artistsSortSetting: ArtistElementSortType = .defaultValue
  public var artistsSortSetting: ArtistElementSortType {
    get { _artistsSortSetting }
    set { _artistsSortSetting = newValue }
  }

  private var _albumsSortSetting: AlbumElementSortType = .defaultValue
  public var albumsSortSetting: AlbumElementSortType {
    get { _albumsSortSetting }
    set { _albumsSortSetting = newValue }
  }

  private var _swipeActionSettings: SwipeActionSettings = .defaultSettings
  /// Always the defaults: the screen that changed them is gone, so a value saved by an older install
  /// (Amperfy's context-queue swipes) must not outlive it.
  public var swipeActionSettings: SwipeActionSettings {
    get { .defaultSettings }
    set { _swipeActionSettings = newValue }
  }

  private var _songsSortSetting: SongElementSortType = .defaultValue
  public var songsSortSetting: SongElementSortType {
    get { _songsSortSetting }
    set {
      if newValue == SongElementSortType.starredDate {
        _songsSortSetting = .defaultValue
      } else {
        _songsSortSetting = newValue
      }
    }
  }

  private var _favoriteSongSortSetting: SongElementSortType = .defaultValueForFavorite
  public var favoriteSongSortSetting: SongElementSortType {
    get { _favoriteSongSortSetting }
    set { _favoriteSongSortSetting = newValue }
  }

  private var _artistsFilterSetting: ArtistCategoryFilter = .defaultValue
  public var artistsFilterSetting: ArtistCategoryFilter {
    get { _artistsFilterSetting }
    set { _artistsFilterSetting = newValue }
  }

  private var _albumsStyleSetting: AlbumsDisplayStyle = .defaultValue
  public var albumsStyleSetting: AlbumsDisplayStyle {
    get { _albumsStyleSetting }
    set { _albumsStyleSetting = newValue }
  }

  private var _podcastsShowSetting: PodcastsShowType = .defaultValue
  public var podcastsShowSetting: PodcastsShowType {
    get { _podcastsShowSetting }
    set { _podcastsShowSetting = newValue }
  }

  private var _playerDisplayStyle: PlayerDisplayStyle = .defaultValue
  public var playerDisplayStyle: PlayerDisplayStyle {
    get { _playerDisplayStyle }
    set { _playerDisplayStyle = newValue }
  }

  private var _albumsGridSizeSetting: Int?
  @MainActor
  public var albumsGridSizeSetting: Int {
    get {
      _albumsGridSizeSetting ?? ((UIDevice.current.userInterfaceIdiom == .pad) ? 4 : 3)
    }
    set { _albumsGridSizeSetting = newValue }
  }
}

// MARK: - AccountSetting

public struct AccountSetting: Sendable, Codable {
  private var _artworkDisplayPreference: ArtworkDisplayPreference = .defaultValue
  public var artworkDisplayPreference: ArtworkDisplayPreference {
    get { _artworkDisplayPreference }
    set { _artworkDisplayPreference = newValue }
  }

  private var _artworkDownloadSetting: ArtworkDownloadSetting = .defaultValue
  public var artworkDownloadSetting: ArtworkDownloadSetting {
    get { _artworkDownloadSetting }
    set { _artworkDownloadSetting = newValue }
  }

  // ordered visible Home Sections
  private var _homeSections: [HomeSection] = HomeSection.defaultValue
  public var homeSections: [HomeSection] {
    get { _homeSections }
    set { _homeSections = newValue }
  }

  // cassette Patch 039: sticky memory for the Library tab's last
  // surfaced category. Mirrors the `_homeSections` Codable pattern —
  // private backing var with a default that survives both fresh
  // installs and decode failures on legacy AccountSetting payloads
  // (Codable auto-synthesis fills in missing keys with the default).
  private var _lastLibraryCategory: LibraryDisplayType = .artists
  public var lastLibraryCategory: LibraryDisplayType {
    get { _lastLibraryCategory }
    set { _lastLibraryCategory = newValue }
  }

  private var _initialSyncCompletionStatus: SyncCompletionStatus = .defaultValue
  public var initialSyncCompletionStatus: SyncCompletionStatus {
    get { _initialSyncCompletionStatus }
    set { _initialSyncCompletionStatus = newValue }
  }

  private var _isAutoDownloadLatestPodcastEpisodesActive: Bool = false
  public var isAutoDownloadLatestPodcastEpisodesActive: Bool {
    get { _isAutoDownloadLatestPodcastEpisodesActive }
    set { _isAutoDownloadLatestPodcastEpisodesActive = newValue }
  }

  // Cassette fork: default to true so newly synced songs auto-download.
  // This makes Cassette Player a download-first client (the product vision)
  // instead of streaming-with-optional-cache. Podcast default left as-is.
  private var _isAutoDownloadLatestSongsActive: Bool = true
  public var isAutoDownloadLatestSongsActive: Bool {
    get { _isAutoDownloadLatestSongsActive }
    set { _isAutoDownloadLatestSongsActive = newValue }
  }

  private var _isScrobbleStreamedItems: Bool = false
  public var isScrobbleStreamedItems: Bool {
    get { _isScrobbleStreamedItems }
    set { _isScrobbleStreamedItems = newValue }
  }

  private var _libraryDisplaySettings: LibraryDisplaySettings = .defaultSettings
  public var libraryDisplaySettings: LibraryDisplaySettings {
    get { _libraryDisplaySettings }
    set { _libraryDisplaySettings = newValue }
  }

  private var _loginCredentials: LoginCredentials? = nil
  public var loginCredentials: LoginCredentials? {
    get { _loginCredentials }
    set { _loginCredentials = newValue }
  }

  private var _themePreference: ThemePreference = .defaultValue
  public var themePreference: ThemePreference {
    get { _themePreference }
    set { _themePreference = newValue }
  }
}

// MARK: - ReadOnlyAccountSetting

public struct ReadOnlyAccountSetting {
  public let read: AccountSetting
}

// MARK: - AccountSettings

public struct AccountSettings: Sendable, Codable {
  fileprivate var _accounts: [AccountInfo: AccountSetting] = [:]
  fileprivate var _activeAccount: AccountInfo?

  public mutating func switchActiveAccount(_ accountInfo: AccountInfo) {
    _activeAccount = accountInfo
  }

  public mutating func login(_ loginCredentials: LoginCredentials) {
    let accountInfo = Account.createInfo(credentials: loginCredentials)
    let newTheme = themeColorForNextNewAccount
    updateSetting(accountInfo) { accountSettings in
      accountSettings.loginCredentials = loginCredentials
      accountSettings.themePreference = newTheme
    }
    _activeAccount = accountInfo
  }

  public func getSetting(_ accountInfo: AccountInfo?) -> ReadOnlyAccountSetting {
    // Settings Priority:
    // 1.: provided account settings (if not nil)
    // 2.: active account settings (if logged in)
    // 3.: default settings
    if let info = accountInfo ?? _activeAccount, let accountSettings = _accounts[info] {
      return ReadOnlyAccountSetting(read: accountSettings)
    } else {
      return ReadOnlyAccountSetting(read: AccountSetting())
    }
  }

  public mutating func logout(_ accountInfo: AccountInfo) {
    _accounts[accountInfo] = nil
    if _activeAccount == accountInfo {
      _activeAccount = _accounts.first?.key
    }
  }

  public mutating func updateSetting(
    _ accountInfo: AccountInfo,
    _ update: (inout AccountSetting) -> ()
  ) {
    var setting = _accounts[accountInfo] ?? AccountSetting()
    update(&setting)
    _accounts[accountInfo] = setting
  }

  public var active: AccountInfo? {
    _activeAccount
  }

  public var activeSetting: ReadOnlyAccountSetting {
    guard let _activeAccount else { return ReadOnlyAccountSetting(read: AccountSetting()) }
    return ReadOnlyAccountSetting(read: _accounts[_activeAccount] ?? AccountSetting())
  }

  public var availableApiTypes: Set<ServerApiType> {
    Set(_accounts.compactMap { $0.value.loginCredentials?.backendApi.asServerApiType })
  }

  public var allAccounts: [AccountInfo] {
    _accounts.compactMap { $0.key }.sorted(by: {
      guard let cred0 = getSetting($0).read.loginCredentials,
            let cred1 = getSetting($1).read.loginCredentials
      else { return false }

      if cred0.displayServerUrl != cred1.displayServerUrl {
        return cred0.displayServerUrl < cred1.displayServerUrl
      } else {
        return cred0.username < cred1.username
      }
    })
  }

  private var themeColorForNextNewAccount: ThemePreference {
    var theme = ThemePreference.blue
    let usedThemes = Set(_accounts.compactMap { $0.value.themePreference })
    let allThemes = Set(ThemePreference.allCases)
    let availableThemes = allThemes.subtracting(usedThemes)
    if let firstAvailable = availableThemes.sorted(by: { $0.rawValue < $1.rawValue }).first {
      theme = firstAvailable
    } else if let activeAccount = _activeAccount {
      let activeTheme = getSetting(activeAccount).read.themePreference
      theme = allThemes.subtracting(Set([activeTheme])).sorted(by: { $0.rawValue < $1.rawValue })
        .first ?? .blue
    }
    return theme
  }
}

// MARK: - AmperfySettings

public struct AmperfySettings: Sendable, Codable {
  // MARK: - Persistence

  private static let decoder: JSONDecoder = .init()
  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
  }()

  private var _appSettings: AppSettings = .init()
  public var app: AppSettings {
    get {
      guard let data = UserDefaults.standard
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsApp.rawValue)
      else { return _appSettings }
      do {
        return try Self.decoder.decode(AppSettings.self, from: data)
      } catch {
        return _appSettings
      }
    }
    set {
      _appSettings = newValue
      do {
        let data = try Self.encoder.encode(_appSettings)
        UserDefaults.standard.set(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsApp.rawValue
        )
      } catch {}
    }
  }

  private var _userSettings: UserSettings = .init()
  public var user: UserSettings {
    get {
      guard let data = UserDefaults.standard
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsUser.rawValue)
      else { return _userSettings }
      do {
        return try Self.decoder.decode(UserSettings.self, from: data)
      } catch {
        return _userSettings
      }
    }
    set {
      _userSettings = newValue
      do {
        let data = try Self.encoder.encode(_userSettings)
        UserDefaults.standard.set(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsUser.rawValue
        )
      } catch {}
    }
  }

  private var _accountSettings: AccountSettings = .init()
  public var accounts: AccountSettings {
    get {
      // In the Keychain, not the preferences file: it holds each music server's login (BUG-878).
      guard let data = SecureSettingsStore
        .data(forKey: PersistentStorage.UserDefaultsKey.SettingsAccount.rawValue)
      else { return _accountSettings }
      do {
        return try Self.decoder.decode(AccountSettings.self, from: data)
      } catch {
        return _accountSettings
      }
    }
    set {
      _accountSettings = newValue
      do {
        let data = try Self.encoder.encode(_accountSettings)
        SecureSettingsStore.setData(
          data,
          forKey: PersistentStorage.UserDefaultsKey.SettingsAccount.rawValue
        )
      } catch {}
    }
  }

  /// Cassette fork — Layer 3: the bearer token obtained during Cassette
  /// pairing/login, reused to authenticate /api/sync/* requests. In the Keychain
  /// with the music-server logins (SecureSettingsStore, BUG-878). `nil` clears it.
  public var cassetteBearerToken: String? {
    get {
      SecureSettingsStore
        .string(forKey: PersistentStorage.UserDefaultsKey.CassetteBearerToken.rawValue)
    }
    set {
      let key = PersistentStorage.UserDefaultsKey.CassetteBearerToken.rawValue
      SecureSettingsStore.setString(newValue?.isEmpty == false ? newValue : nil, forKey: key)
    }
  }
}

// MARK: - SecureSettingsStore

/// The Keychain for what can sign this phone in: the Cassette sign-in and the saved
/// music-server logins (BUG-878). They used to sit in the preferences file, which goes
/// into every backup and onto any phone a backup is restored to. Kept after first
/// unlock (background downloads and sync run with the phone locked) and on this
/// device only. Reads are cached in memory, because the logins are read on nearly
/// every screen and request. The first read moves what an older version left in the
/// preferences file across, and removes it there once the Keychain holds it.
public enum SecureSettingsStore {
  private static let service = "digital.cassette.settings"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [String: Data] = [:]
  nonisolated(unsafe) private static var known: Set<String> = []

  public static func string(forKey key: String) -> String? {
    read(key, legacy: { UserDefaults.standard.string(forKey: key)?.data(using: .utf8) })
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  public static func setString(_ value: String?, forKey key: String) {
    write(value?.data(using: .utf8), forKey: key, legacy: { UserDefaults.standard.set(value, forKey: key) })
  }

  public static func data(forKey key: String) -> Data? {
    read(key, legacy: { UserDefaults.standard.data(forKey: key) })
  }

  public static func setData(_ data: Data?, forKey key: String) {
    write(data, forKey: key, legacy: { UserDefaults.standard.set(data, forKey: key) })
  }

  private static func read(_ key: String, legacy: () -> Data?) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if known.contains(key) { return cache[key] }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query(key, [
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]) as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      UserDefaults.standard.removeObject(forKey: key)
      remember(data, key)
      return data
    }
    // Locked before the first unlock since a restart, or another failure: answer from the
    // preferences file if an older version left it there, and decide nothing for good.
    guard status == errSecItemNotFound else { return legacy() }
    guard let moving = legacy() else {
      remember(nil, key)
      return nil
    }
    if store(moving, key) { UserDefaults.standard.removeObject(forKey: key) }
    remember(moving, key)
    return moving
  }

  private static func write(_ data: Data?, forKey key: String, legacy: () -> ()) {
    lock.lock()
    defer { lock.unlock() }
    guard let data else {
      SecItemDelete(query(key) as CFDictionary)
      UserDefaults.standard.removeObject(forKey: key)
      remember(nil, key)
      return
    }
    // A Keychain that can't be written (locked since a restart) keeps the old behaviour
    // rather than losing the sign-in; the next read moves it across.
    if store(data, key) {
      UserDefaults.standard.removeObject(forKey: key)
    } else {
      legacy()
    }
    remember(data, key)
  }

  private static func store(_ data: Data, _ key: String) -> Bool {
    let update = SecItemUpdate(query(key) as CFDictionary, [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ] as CFDictionary)
    if update == errSecSuccess { return true }
    guard update == errSecItemNotFound else { return false }
    return SecItemAdd(query(key, [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]) as CFDictionary, nil) == errSecSuccess
  }

  private static func query(_ key: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    q.merge(extra) { _, new in new }
    return q
  }

  private static func remember(_ data: Data?, _ key: String) {
    cache[key] = data
    known.insert(key)
  }
}
