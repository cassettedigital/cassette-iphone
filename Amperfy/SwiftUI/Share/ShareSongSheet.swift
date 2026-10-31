//
//  ShareSongSheet.swift
//  Amperfy
//
//  Cassette: send a song (CASSETTE_SHARING.md). Share opens Apple's share sheet at once with the song's
//  link, and the friend's page says who it's from. A note is one row inside that sheet, Add a Note, so a
//  raw share stays one tap and a note, any length, is there for whoever wants one: the note sheet, then
//  Apple's share sheet again with the same link, now carrying the note.
//
//  The link's code is made here, so the sheet opens without a round trip. The share is saved in the
//  cloud as the sheet opens (POST /api/share/song), and the link only goes to the app the person picks
//  once it is saved (ShareSongLink), because WhatsApp and the rest fetch a preview the moment it lands.
//  Whether a song can be shared at all (one of its videos still plays) is asked before Share is offered
//  (ShareSongAvailability): a song with no video shows Share greyed out instead of failing afterwards.
//
//  Apple's parts throughout: UIActivityViewController with LPLinkMetadata built from the album cover, a
//  UIActivity for Add a Note, and for the note a page sheet with a vertical TextField, a segmented
//  Picker for the start moment and a prominent Button.
//
//  A note being written survives the note sheet being swiped away (ShareSongDrafts) until it is sent.

import AmperfyKit
import LinkPresentation
import SwiftUI

// MARK: - What the sheets need to know about the song

struct ShareSongSubject: Sendable {
  let songId: String
  let title: String
  let artist: String
  let cassetteLocalId: String
  let mbid: String?
  /// The album's cover as this phone holds it, for the link preview and the note sheet.
  let cover: UIImage?
  /// Seconds into the song when Share was pressed, when it is the one playing and the moment is
  /// worth offering (past the first few seconds, before the last few). Nil otherwise.
  let elapsed: Int?

  /// The link preview's title, in the same words as the friend's page.
  var linkTitle: String { "Listen to \(title) by \(artist) on Cassette" }

  @MainActor
  init(song: Song, player: PlayerFacade?) {
    songId = song.id
    title = song.title
    artist = song.creatorName
    cassetteLocalId = CassetteCloudPlaylistBridge.cassetteLocalId(for: song)
    mbid = song.musicBrainzId
    // a song shows its album's cover (the song's own artwork is usually empty)
    let app = UIApplication.shared.delegate as! AppDelegate
    cover = LibraryEntityImage.coverImage(
      libraryEntity: song,
      artworkDisplayPreference: app.storage.settings.accounts.activeSetting.read.artworkDisplayPreference,
      useCache: true
    )
    if let player, player.currentlyPlaying?.asSong?.id == song.id {
      let at = Int(player.elapsedTime)
      elapsed = (at >= 3 && (song.duration == 0 || at <= song.duration - 5)) ? at : nil
    } else {
      elapsed = nil
    }
  }
}

// MARK: - Whether a song can be sent

/// Whether each song can be shared right now, asked once and kept for a while (a video can turn up
/// later, or stop playing), so Now Playing and the long-press menu know before anyone presses Share.
@MainActor
final class ShareSongAvailability {
  static let shared = ShareSongAvailability()

  private var answers: [String: (shareable: Bool, at: Date)] = [:]
  private var asking: [String: Task<Bool?, Never>] = [:]
  private let keepFor: TimeInterval = 30 * 60

  /// The answer already in hand, or nil when it hasn't been asked lately.
  func known(_ songId: String) -> Bool? {
    guard let answer = answers[songId], Date().timeIntervalSince(answer.at) < keepFor else { return nil }
    return answer.shareable
  }

  /// Ask the cloud, once per song at a time. Nil when it couldn't be asked (offline, signed out):
  /// Share stays on, and saving the share says what went wrong.
  func check(_ song: Song) async -> Bool? {
    if let answer = known(song.id) { return answer }
    let songId = song.id
    if let pending = asking[songId] { return await pending.value }
    let local = CassetteCloudPlaylistBridge.cassetteLocalId(for: song)
    let mbid = song.musicBrainzId
    let pending = Task { () -> Bool? in
      try? await CassetteSyncAPI.shared.checkSongShare(
        cassetteLocalId: local,
        mbid: mbid,
        subsonicTrackId: songId
      )
    }
    asking[songId] = pending
    let answer = await pending.value
    asking[songId] = nil
    if let answer { answers[songId] = (answer, Date()) }
    return answer
  }

  /// A save came back saying the song has no video: Share greys out for it from now on.
  func markUnshareable(_ songId: String) {
    answers[songId] = (false, Date())
  }
}

// MARK: - The link's code

/// The 8-character code in a share's link (/s/<code>), the shape the cloud makes for the web's shares.
enum ShareSongCode {
  private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

  static func make() -> String {
    String((0 ..< 8).map { _ in alphabet.randomElement()! })
  }

  static func link(_ code: String) -> URL? {
    URL(string: "https://cassette.digital/s/\(code)")
  }
}

// MARK: - Saving the share behind the sheet

/// One share being saved. Started as Apple's share sheet opens; the link waits on it before it goes to
/// the app the person picked (on the share sheet's own background thread), and the sheet's completion
/// reads how it went.
final class ShareSongSave: @unchecked Sendable {
  enum Outcome: Sendable { case saved, noVideo, signedOut, failed }

  private let lock = NSLock()
  private var outcome: Outcome?
  private var picked = false
  private(set) var task: Task<Outcome, Never>!

  /// `after`: the save already made for this link (the plain share, before Add a Note), which this one
  /// waits for, so the note it carries is never overwritten by the earlier save landing late.
  @MainActor
  static func start(
    _ subject: ShareSongSubject,
    code: String,
    note: String?,
    startSeconds: Int?,
    after earlier: ShareSongSave? = nil
  )
    -> ShareSongSave {
    let save = ShareSongSave()
    save.task = Task {
      _ = await earlier?.task.value
      let result: Outcome
      do {
        let answer = try await CassetteSyncAPI.shared.createSongShare(
          id: code,
          cassetteLocalId: subject.cassetteLocalId,
          mbid: subject.mbid,
          subsonicTrackId: subject.songId,
          note: note,
          startSeconds: startSeconds
        )
        result = answer.ok ? .saved : (answer.reason == "no_video" ? .noVideo : .failed)
      } catch CassetteSyncError.notAuthenticated {
        result = .signedOut
      } catch {
        result = .failed
      }
      save.lock.withLock { save.outcome = result }
      return result
    }
    return save
  }

  /// The person picked where to send it: wait for the save, which has almost always landed by now.
  /// Called on the share sheet's background thread.
  func waitUntilSaved(timeout: TimeInterval) {
    lock.withLock { picked = true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, lock.withLock({ outcome }) == nil {
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  /// Whether the link has gone to an app yet.
  var wasPicked: Bool { lock.withLock { picked } }

  /// How the save went, once it has.
  var settled: Outcome? { lock.withLock { outcome } }
}

// MARK: - The link Apple's share sheet hands on

extension UIActivity.ActivityType {
  /// Add a Note, Cassette's own row in the share sheet.
  static let cassetteAddNote = UIActivity.ActivityType("digital.cassette.player.share-add-note")
}

/// The shared link: its preview ready at once, built from the album cover so the share sheet draws it
/// without fetching the page, and the link itself only once the share is saved.
final class ShareSongLink: UIActivityItemProvider, @unchecked Sendable {
  private let link: URL
  private let title: String
  private let cover: UIImage?
  private let save: ShareSongSave

  init(link: URL, title: String, cover: UIImage?, save: ShareSongSave) {
    self.link = link
    self.title = title
    self.cover = cover
    self.save = save
    super.init(placeholderItem: link)
  }

  override var item: Any {
    if activityType != .cassetteAddNote { save.waitUntilSaved(timeout: 10) }
    return link
  }

  override func activityViewController(
    _: UIActivityViewController,
    subjectForActivityType _: UIActivity.ActivityType?
  )
    -> String { title }

  override func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
    // With no cover on this phone, no preview of our own: Messages then reads the page's, which has one.
    // A preview handed over without a picture would be sent as it is.
    guard let cover else { return nil }
    let metadata = LPLinkMetadata()
    metadata.originalURL = link
    metadata.url = link
    metadata.title = title
    metadata.imageProvider = NSItemProvider(object: cover)
    metadata.iconProvider = NSItemProvider(object: cover)
    return metadata
  }
}

/// Add a Note: a row in Apple's share sheet that opens the note sheet, then the share sheet again.
final class ShareSongAddNote: UIActivity {
  override class var activityCategory: UIActivity.Category { .action }
  override var activityType: UIActivity.ActivityType? { .cassetteAddNote }
  override var activityTitle: String? { "Add a Note" }
  override var activityImage: UIImage? { UIImage(systemName: "square.and.pencil") }
  override func canPerform(withActivityItems _: [Any]) -> Bool { true }
  override func perform() { activityDidFinish(true) }
}

// MARK: - Drafts

/// A note being written, kept per song until it is sent, so swiping the sheet away never loses it.
@MainActor
enum ShareSongDrafts {
  private static var notes: [String: String] = [:]
  static func note(for songId: String) -> String { notes[songId] ?? "" }
  static func keep(_ note: String, for songId: String) {
    notes[songId] = note.isEmpty ? nil : note
  }

  static func clear(_ songId: String) { notes[songId] = nil }
}

// MARK: - The note sheet

struct ShareSongNoteSheet: View {
  let subject: ShareSongSubject
  let onSend: (_ note: String?, _ startSeconds: Int?) -> ()

  @State
  private var note: String
  @State
  private var fromHere = false
  @FocusState
  private var writing: Bool

  init(subject: ShareSongSubject, onSend: @escaping (_ note: String?, _ startSeconds: Int?) -> ()) {
    self.subject = subject
    self.onSend = onSend
    _note = State(initialValue: ShareSongDrafts.note(for: subject.songId))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      songRow
      if let elapsed = subject.elapsed {
        Picker("Starts", selection: $fromHere) {
          Text("From the start").tag(false)
          Text("From \(clock(elapsed))").tag(true)
        }
        .pickerStyle(.segmented)
      }
      TextField("Add a note", text: $note, axis: .vertical)
        .lineLimit(1 ... 14)
        .font(Font.cassette(.body))
        .foregroundStyle(Color.cassette(.textPrimary))
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.cassette(.surfaceRaised))
        )
        .focused($writing)
        .onChange(of: note) { _, value in
          ShareSongDrafts.keep(value, for: subject.songId)
        }
      Spacer(minLength: 0)
      Button {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onSend(trimmed.isEmpty ? nil : trimmed, fromHere ? subject.elapsed : nil)
      } label: {
        Text("Send")
          .foregroundStyle(Color.cassette(.textOnFill))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.cassette(.fillSelected))
      .controlSize(.large)
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 16)
    .background(Color.cassette(.surfaceBase))
    .task {
      // the person asked to write a note: the keyboard comes up once the sheet has settled
      try? await Task.sleep(for: .milliseconds(250))
      writing = true
    }
  }

  private var songRow: some View {
    HStack(spacing: 12) {
      Group {
        if let cover = subject.cover {
          Image(uiImage: cover).resizable().scaledToFill()
        } else {
          RoundedRectangle(cornerRadius: 4).fill(Color.cassette(.surfaceRaised))
        }
      }
      .frame(width: 52, height: 52)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(subject.title)
          .font(Font.cassette(.rowTitle))
          .foregroundStyle(Color.cassette(.textPrimary))
          .lineLimit(1)
        Text(subject.artist)
          .font(Font.cassette(.cardSubtitle))
          .foregroundStyle(Color.cassette(.textSecondary))
          .lineLimit(1)
      }
    }
  }

  private func clock(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

// MARK: - Presentation

extension UIViewController {
  /// Share a song from any screen (a song's long-press menu, Now Playing): Apple's share sheet at once.
  @MainActor
  func presentShareSong(_ song: Song) {
    let subject = ShareSongSubject(song: song, player: appDelegate.player)
    if ShareSongAvailability.shared.known(song.id) == false {
      presentShareProblem(.noVideo, songId: subject.songId, sent: false)
      return
    }
    presentSongShareSheet(subject, code: ShareSongCode.make(), note: nil, startSeconds: nil, offerNote: true)
  }

  @MainActor
  private func presentSongShareSheet(
    _ subject: ShareSongSubject,
    code: String,
    note: String?,
    startSeconds: Int?,
    offerNote: Bool,
    after earlier: ShareSongSave? = nil
  ) {
    guard let link = ShareSongCode.link(code) else { return }
    let save = ShareSongSave.start(subject, code: code, note: note, startSeconds: startSeconds, after: earlier)
    let sheet = UIActivityViewController(
      activityItems: [ShareSongLink(link: link, title: subject.linkTitle, cover: subject.cover, save: save)],
      applicationActivities: offerNote ? [ShareSongAddNote()] : nil
    )
    sheet.completionWithItemsHandler = { [weak self] type, completed, _, _ in
      Task { @MainActor in
        guard let self else { return }
        if type == .cassetteAddNote {
          // never a note for a song that turned out to have nothing to send
          if let early = save.settled, early != .saved {
            self.presentShareProblem(early, songId: subject.songId, sent: false)
            return
          }
          // the same link, so a note added now rides the link that hadn't gone anywhere yet
          self.presentShareNote(subject, code: code, after: save)
          return
        }
        guard completed else { return }
        let outcome = await save.task.value
        if outcome == .saved {
          ShareSongDrafts.clear(subject.songId)
        } else {
          self.presentShareProblem(outcome, songId: subject.songId, sent: true)
        }
      }
    }
    // a save that fails before anything is picked closes the sheet and says why, so nothing goes out
    Task { @MainActor [weak self, weak sheet] in
      let outcome = await save.task.value
      guard outcome != .saved, !save.wasPicked, let sheet,
            sheet.presentingViewController != nil, !sheet.isBeingDismissed
      else { return }
      sheet.dismiss(animated: true) {
        self?.presentShareProblem(outcome, songId: subject.songId, sent: false)
      }
    }
    // iPad: the share sheet is a popover and needs somewhere to point
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    present(sheet, animated: true)
  }

  @MainActor
  private func presentShareNote(_ subject: ShareSongSubject, code: String, after earlier: ShareSongSave) {
    weak var hostRef: UIHostingController<ShareSongNoteSheet>?
    let sheet = ShareSongNoteSheet(subject: subject) { [weak self] note, startSeconds in
      hostRef?.dismiss(animated: true) {
        self?.presentSongShareSheet(
          subject,
          code: code,
          note: note,
          startSeconds: startSeconds,
          offerNote: false,
          after: earlier
        )
      }
    }
    let host = UIHostingController(rootView: sheet)
    hostRef = host
    host.view.backgroundColor = UIColor(Color.cassette(.surfaceBase))
    if let sheetController = host.sheetPresentationController {
      sheetController.detents = [.large()]
      sheetController.prefersGrabberVisible = true
      sheetController.preferredCornerRadius = 28
    }
    present(host, animated: true)
  }

  @MainActor
  private func presentShareProblem(_ outcome: ShareSongSave.Outcome, songId: String, sent: Bool) {
    let title: String
    let message: String
    switch outcome {
    case .noVideo:
      ShareSongAvailability.shared.markUnshareable(songId)
      title = "No Video to Share Yet"
      message = sent
        ? "There's no video for this song yet, so the link you sent won't open."
        : "There's no video for this song yet, so a link to it wouldn't open."
    case .signedOut:
      title = "Sign In to Share"
      message = "Sign in to Cassette to send songs."
    case .saved, .failed:
      title = sent ? "That Link Didn't Save" : "Couldn't Share That Song"
      message = sent
        ? "It won't open for them. Check your connection and share it again."
        : "Check your connection and try again."
    }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
