import AppKit
import SwiftUI

/// The impure half of Direct Dictation: owns the services, translates
/// trigger-monitor events into DictationSessionMachine actions, runs the
/// begin guards, and executes the machine's effects. Every state transition
/// lives in the machine; async completions come back to it as new actions.
@MainActor
final class DirectDictationController {
  /// Carries the session's captured settings while recording so the shell
  /// can mirror session-scoped looks (the status ghost's palette tint);
  /// nil when the session ends.
  var onRecordingStateChange: ((Bool, DictationSessionSettings?) -> Void)?
  /// Fired by the Read Aloud shortcut, only while no dictation session is
  /// active — speaking through the speaker path mid-dictation would feed
  /// the recognizer its own audio.
  var onReadAloudTriggered: (() -> Void)?
  /// A language model downloading, as a locale identifier and progress (0…1),
  /// or nil progress once it finishes. Settings shows it on the language row.
  var onLanguageDownloadChange: ((String, Double?) -> Void)?

  private static let noSpeechTimeout = Duration.seconds(15)

  private let settings: AppSettings
  private let speechService = SpeechRecognitionService()
  private let hudController: DictationHUDController
  private let textInsertionService = TextInsertionService()
  private let usageTracker: UsageTracker

  private var keyEventMonitor: GlobalKeyEventMonitor?
  private var machine = DictationSessionMachine()
  private var focusedTarget: TextInsertionService.Target?
  private var noSpeechTask: Task<Void, Never>?
  private var permissionTask: Task<Void, Never>?
  private var permissionWatchTask: Task<Void, Never>?
  private var sessionStartTask: Task<Void, Never>?
  private var isPrepared = false
  private var preparationFailureMessage: String?
  private var currentSessionSettings: DictationSessionSettings?
  /// The languages behind the two trigger keys, resolved to locales Apple
  /// Speech supports. `secondary` is nil unless a second language is chosen.
  private var primaryLocale: Locale?
  private var secondaryLocale: Locale?
  /// Which slot's key began the session in flight, so the session runs in
  /// the language of the key that started it even if Settings change.
  private var activeSlot: GlobalKeyEventMonitor.TriggerSlot = .primary

  init(
    settings: AppSettings,
    hudController: DictationHUDController,
    usageTracker: UsageTracker
  ) {
    self.settings = settings
    self.hudController = hudController
    self.usageTracker = usageTracker
    keyEventMonitor = GlobalKeyEventMonitor { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handle(event)
      }
    }
  }

  func start() {
    applyKeyBindings()
    observeModelDownloads()
    requestPermissionsAndPrepare()
  }

  /// Routes model downloads to both places they matter: the Language section,
  /// and the HUD when a session is already waiting on that very language.
  private func observeModelDownloads() {
    let handler: @Sendable (SpeechRecognitionService.ModelDownload) -> Void = { [weak self] download in
      Task { @MainActor in
        self?.receive(download)
      }
    }

    Task { [speechService] in
      await speechService.setDownloadHandler(handler)
    }
  }

  private func receive(_ download: SpeechRecognitionService.ModelDownload) {
    onLanguageDownloadChange?(download.locale.identifier, download.fraction)

    // Only speak up in the HUD for the language this session is waiting on.
    guard machine.isSessionActive, locale(for: activeSlot) == download.locale else { return }

    guard let fraction = download.fraction else {
      hudController.showModelDownload(nil)
      return
    }
    let name = SpeechLanguageCatalog.shortName(for: download.locale)
    hudController.showModelDownload(
      "Downloading \(name)… \(Int(fraction * 100))%"
    )
  }

  /// Pushes the recorded Settings bindings into the event tap; called at
  /// start and whenever the Shortcuts section changes them.
  func applyKeyBindings() {
    keyEventMonitor?.setBindings(
      trigger: settings.dictationTriggerBinding,
      secondaryTrigger: settings.isSecondLanguageEnabled
        ? settings.secondaryTriggerBinding
        : nil,
      readAloud: settings.readAloudBinding
    )
    keyEventMonitor?.setEventHandlingSuspended(settings.isRecordingKeybind)
  }

  /// Re-resolves both languages and warms them. Called whenever the Language
  /// section changes a pick, so the key you press next is already prepared
  /// rather than building its analyzer on the keypress.
  func applyLanguages() {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareLanguages()
        isPrepared = true
        preparationFailureMessage = nil
      } catch {
        isPrepared = false
        preparationFailed(message: error.localizedDescription)
      }
    }
  }

  /// Resolves both picks, drops anything no longer bound to a key, then warms
  /// the primary language. The second warms behind it and never throws: a
  /// model that still needs downloading must not delay the primary key.
  private func prepareLanguages() async throws {
    let primary = try await speechService.resolveLocale(
      identifier: settings.recognitionLocaleIdentifier
    )
    primaryLocale = primary

    // Resolved strictly: a stored pick this Mac cannot transcribe drops the
    // second language instead of quietly becoming the system default, which
    // would dictate in a language the user never chose.
    var secondary: Locale?
    if settings.isSecondLanguageEnabled {
      secondary = await speechService.supportedLocale(
        identifier: settings.secondaryRecognitionLocaleIdentifier
      )
    }
    // A second language equal to the first is not a second language.
    secondaryLocale = secondary == primary ? nil : secondary

    let bound = [primary, secondaryLocale].compactMap(\.self)
    await speechService.retainOnly(locales: bound)
    try await speechService.prewarm(locale: primary)

    if let secondaryLocale {
      try? await speechService.prewarm(locale: secondaryLocale)
    }
  }

  private func locale(for slot: GlobalKeyEventMonitor.TriggerSlot) -> Locale? {
    switch slot {
    case .primary: primaryLocale
    case .secondary: secondaryLocale ?? primaryLocale
    }
  }

  /// The HUD's language tag, shown only once a second language exists: with
  /// one language there is nothing to disambiguate.
  private var activeLanguageTag: String? {
    guard secondaryLocale != nil, let locale = locale(for: activeSlot) else { return nil }
    return SpeechLanguageCatalog.tag(for: locale)
  }

  func stop() {
    noSpeechTask?.cancel()
    permissionTask?.cancel()
    permissionWatchTask?.cancel()
    sessionStartTask?.cancel()
    keyEventMonitor?.stop()
    isPrepared = false

    Task {
      await speechService.shutDown()
    }
  }

  func toggleFromMenu() {
    // The menu item has no language of its own, so it dictates in the first.
    if !machine.isSessionActive {
      activeSlot = .primary
    }
    send(.menuToggled(now: .now))
  }

  func requestPermissionsAndPrepare() {
    permissionTask?.cancel()
    isPrepared = false
    preparationFailureMessage = nil

    permissionTask = Task { [weak self] in
      guard let self else { return }

      let microphoneGranted = await PermissionService.requestMicrophoneAccess()
      guard !Task.isCancelled else { return }
      guard microphoneGranted else {
        preparationFailed(message: "Microphone permission required")
        return
      }

      let speechGranted = await PermissionService.requestSpeechAccess()
      guard !Task.isCancelled else { return }
      guard speechGranted else {
        preparationFailed(message: "Speech permission required")
        return
      }

      // Ask for one privacy permission at a time. Requesting Accessibility
      // beside the microphone prompt makes macOS stack or suppress dialogs.
      PermissionService.requestAccessibilityAccess()

      do {
        try await prepareLanguages()
      } catch {
        guard !Task.isCancelled else { return }
        preparationFailed(message: error.localizedDescription)
        return
      }

      isPrepared = true
      installTriggerMonitor()
    }
  }

  /// Watches for a permission the user is granting right now.
  ///
  /// Accessibility is granted in System Settings while Talkify is already
  /// running, and macOS tells the app nothing when it changes. Checking once at
  /// launch meant the trigger key stayed dead after the user had done everything
  /// right, with no hint that a relaunch was needed. This polls instead, and
  /// installs the tap the moment it is allowed to.
  private func startPermissionWatch() {
    guard permissionWatchTask == nil else { return }

    permissionWatchTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        // Never interrupt the dialog the user is reading.
        guard !PermissionAlert.isPresenting else { continue }
        guard PermissionService.hasAccessibilityAccess else { continue }

        permissionWatchTask = nil
        if keyEventMonitor?.start() == true {
          hudController.showMessage("Talkify is ready")
        } else {
          PermissionAlert.requestRelaunch()
        }
        return
      }
    }
  }

  private func handle(_ event: GlobalKeyEventMonitor.Event) {
    switch event {
    case let .triggerPressed(slot):
      // While a session runs, only the key that started it controls it. The
      // other language's key is inert until this session ends, so a latched
      // German session cannot be stopped by the English key.
      if machine.isSessionActive {
        guard slot == activeSlot else { return }
      } else {
        activeSlot = slot
      }
      send(.triggerPressed(now: .now))
    case let .triggerReleased(slot):
      guard slot == activeSlot else { return }
      send(.triggerReleased(now: .now))
    case .cancelPressed:
      send(.escapePressed)
    case .returnPressed:
      send(.returnPressed)
    case .readAloudPressed:
      send(.readAloudPressed)
    }
  }

  private func send(_ action: DictationSessionMachine.Action) {
    perform(machine.reduce(action))
  }

  private func perform(_ effects: [DictationSessionMachine.Effect]) {
    for effect in effects {
      perform(effect)
    }
  }

  private func perform(_ effect: DictationSessionMachine.Effect) {
    switch effect {
    case .checkAndBegin:
      checkAndBegin()
    case .beginRecognition:
      beginRecognition()
    case let .finishRecognition(speakingDuration):
      finishRecognition(speakingDuration: speakingDuration)
    case .cancelRecognition:
      Task { [weak self] in
        guard let self else { return }
        await speechService.cancel()
        send(.sessionEnded)
      }
    case .cancelStartTask:
      sessionStartTask?.cancel()
    case let .setEscapeCapture(enabled):
      keyEventMonitor?.setEscapeCaptureEnabled(enabled)
    case let .setReturnCapture(enabled):
      keyEventMonitor?.setReturnCaptureEnabled(enabled)
    case .startNoSpeechTimer:
      startNoSpeechTimer()
    case .stopNoSpeechTimer:
      stopNoSpeechTimer()
    case let .showListening(latched):
      let session = settings.sessionSettings
      currentSessionSettings = session
      hudController.showListening(
        on: focusedTarget?.displayID,
        isLatched: latched,
        settings: session,
        languageTag: activeLanguageTag
      )
    case .showLatched:
      hudController.showLatched()
    case .showLiveText:
      if let pendingLiveText {
        hudController.showLiveText(pendingLiveText)
      }
    case .showFinalizing:
      hudController.showFinalizing()
    case .showEditableDraft:
      showEditableDraft()
    case .pasteDraft:
      pasteDraft()
    case .hideHUD:
      hudController.hide()
    case let .notifyRecording(isRecording):
      if !isRecording {
        focusedTarget = nil
        sessionStartTask = nil
        currentSessionSettings = nil
        sessionSpeakingDuration = 0
        pendingReplacement = nil
      }
      onRecordingStateChange?(isRecording, currentSessionSettings)
    case .triggerReadAloud:
      onReadAloudTriggered?()
    }
  }

  /// The text carried alongside the current `updateReceived` action; the
  /// machine decides whether it shows, the controller remembers what.
  private var pendingLiveText: String?

  private func checkAndBegin() {
    // A replacement round targets the HUD's own selection: the session's
    // outer target stays captured, and the round's words splice into the
    // held draft when they arrive. Nothing here can reject a round — the
    // recognizer the session already runs on is warm by definition.
    if machine.isReviewing {
      pendingReplacement = captureDraftSelection()
      send(.beginApproved)
      return
    }

    guard isPrepared else {
      hudController.showMessage(preparationFailureMessage ?? "Preparing speech…")
      send(.beginRejected)
      return
    }

    if !PermissionService.hasAccessibilityAccess {
      // One dialog that explains it, not the system prompt again on every press.
      PermissionAlert.requestAccessibilitySetup()
      startPermissionWatch()
      send(.beginRejected)
      return
    }

    let target = textInsertionService.captureFocusedTarget()
    if target?.isSecure == true {
      hudController.showMessage("Secure field", on: target?.displayID)
      send(.beginRejected)
      return
    }

    focusedTarget = target
    send(.beginApproved)
  }

  private func beginRecognition() {
    guard let locale = locale(for: activeSlot) else {
      fail(message: "Preparing speech…", wasCancelled: false)
      return
    }

    sessionStartTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await speechService.start(
          locale: locale,
          updateHandler: { [weak self] update in
            Task { @MainActor [weak self] in
              self?.receive(update)
            }
          },
          failureHandler: { [weak self] message in
            Task { @MainActor [weak self] in
              self?.fail(message: message, wasCancelled: false)
            }
          },
          levelHandler: { [weak self] level in
            Task { @MainActor [weak self] in
              self?.hudController.showAudioLevel(level)
            }
          }
        )
        guard !Task.isCancelled else {
          await speechService.cancel()
          send(.sessionEnded)
          return
        }
        sessionStartTask = nil
        send(.recognitionStarted(now: .now))
      } catch {
        sessionStartTask = nil
        if Task.isCancelled {
          send(.recognitionFailed(wasCancelled: true))
        } else {
          fail(message: error.localizedDescription, wasCancelled: false)
        }
      }
    }
  }

  private func receive(_ update: SpeechRecognitionService.Update) {
    let displayText = update.displayText
    let hasVisibleText = !displayText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    pendingLiveText = displayText
    send(.updateReceived(hasVisibleText: hasVisibleText))
    pendingLiveText = nil
  }

  /// Finishes recognition and routes the outcome to its terminal UI.
  ///
  /// The default path inserts as before. The editable-draft variant holds
  /// the text in the HUD instead: the machine moves to `.reviewing`, where
  /// Return pastes, the trigger starts a replacement round, and Escape
  /// discards. A replacement round's text is spliced into the held draft at
  /// the selection the round began with, and every round's speech time
  /// joins the session's total for Insights.
  ///
  /// - Parameter speakingDuration: The completed round's measured speech time.
  private func finishRecognition(speakingDuration: TimeInterval) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let text = try await speechService.finish()
        sessionSpeakingDuration += speakingDuration
        if let pending = pendingReplacement {
          commitReplacement(text, into: pending)
        } else if currentSessionSettings?.draftStyle == .editableDraft {
          // The main round of an editable-draft session: hold the draft
          // for review instead of inserting. An empty draft has nothing
          // to review, so the session simply ends as today.
          if text.isEmpty {
            hudController.hide()
            send(.sessionEnded)
          } else {
            hudController.setDraft(text)
            send(.finishCompleted)
          }
        } else {
          hudController.hide()
          let outcome = await textInsertionService.insert(text, into: focusedTarget)
          switch outcome {
          case .inserted, .copiedToClipboard:
            hudController.playPasteSound()
            send(.sessionEnded)
            let wordCount = UsageMetrics.wordCount(in: text)
            await usageTracker.recordSession(
              wordCount: wordCount,
              speakingDuration: speakingDuration
            )
          case .unavailable:
            send(.sessionEnded)
            hudController.showMessage("Couldn't insert text")
          }
        }
      } catch {
        fail(message: error.localizedDescription, wasCancelled: false)
      }
    }
  }

  /// The draft and the selection a replacement round began with, so the
  /// round can put the draft back (when it delivers nothing) or splice its
  /// words into exactly that range (when it does).
  private struct PendingReplacement {
    let draft: String
    let range: NSRange
  }

  private var pendingReplacement: PendingReplacement?
  /// The session's accumulated speech time across every round, recorded
  /// when the reviewed draft is pasted.
  private var sessionSpeakingDuration: TimeInterval = 0

  /// Freezes the draft and the field's selection before the listening state
  /// overwrites the band with the round's live text.
  private func captureDraftSelection() -> PendingReplacement? {
    let draft = hudController.draftText
    let range = hudController.draftSelectionRange
      ?? NSRange(location: draft.utf16.count, length: 0)
    return PendingReplacement(draft: draft, range: range)
  }

  /// Commits a replacement round's recognized text into the held draft: it
  /// replaces exactly the selection the round began with, and the cursor
  /// lands after the inserted words. A round that delivered nothing leaves
  /// the draft untouched.
  private func commitReplacement(_ text: String, into pending: PendingReplacement) {
    pendingReplacement = nil
    if text.isEmpty {
      hudController.setDraft(pending.draft)
    } else if let range = Range(pending.range, in: pending.draft) {
      let draft = pending.draft.replacingCharacters(in: range, with: text)
      let cursor = String.Index(utf16Offset: pending.range.upperBound, in: draft)
      hudController.setDraft(draft, selection: TextSelection(insertionPoint: cursor))
    } else {
      hudController.setDraft(pending.draft)
    }
    send(.finishCompleted)
  }

  /// Puts the HUD back into the review: the field returns with the draft
  /// restored if a replacement round never delivered.
  private func showEditableDraft() {
    if let pending = pendingReplacement {
      pendingReplacement = nil
      hudController.setDraft(pending.draft)
    }
    hudController.showEditableDraft()
  }

  /// Return while the draft is under review: the edited draft is delivered
  /// to the session's target exactly like the release flow delivers a
  /// finished session — same service, same clipboard-restore semantics,
  /// same paste sound. The panel resigns key with the retract, which hands
  /// the captured control back its AX focus, so the insertion validates
  /// and pastes into the right place.
  private func pasteDraft() {
    Task { [weak self] in
      guard let self else { return }
      let text = hudController.draftText
      hudController.hide()
      let outcome = await textInsertionService.insert(text, into: focusedTarget)
      switch outcome {
      case .inserted, .copiedToClipboard:
        hudController.playPasteSound()
        send(.sessionEnded)
        let wordCount = UsageMetrics.wordCount(in: text)
        await usageTracker.recordSession(
          wordCount: wordCount,
          speakingDuration: sessionSpeakingDuration
        )
      case .unavailable:
        send(.sessionEnded)
        hudController.showMessage("Couldn't insert text")
      }
    }
  }

  /// A failure path always ends with the message shown after the reset —
  /// the machine handles the transition, the controller the message.
  private func fail(message: String, wasCancelled: Bool) {
    let effects = machine.reduce(.recognitionFailed(wasCancelled: wasCancelled))
    guard !effects.isEmpty else { return }

    if effects.contains(.cancelRecognition) {
      // Active failure: cancel recognition, reset, then show why.
      for effect in effects where effect != .cancelRecognition {
        perform(effect)
      }
      Task { [weak self] in
        guard let self else { return }
        await speechService.cancel()
        send(.sessionEnded)
        // A replacement round that failed leaves the session back in
        // `.reviewing` with the draft intact; the review coming back IS
        // the signal, and a message would evict it.
        if !machine.isReviewing {
          hudController.showMessage(message)
        }
      }
    } else {
      perform(effects)
    }
  }

  private func startNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = Task { [weak self] in
      try? await Task.sleep(for: Self.noSpeechTimeout)
      guard !Task.isCancelled else { return }
      self?.send(.noSpeechTimedOut)
    }
  }

  private func stopNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = nil
  }

  private func installTriggerMonitor() {
    guard PermissionService.hasAccessibilityAccess else {
      PermissionService.requestAccessibilityAccess()
      startPermissionWatch()
      return
    }

    // Granted, but macOS decides what this process may do when it launches, so
    // the tap can still be refused. Only a fresh launch clears that, and saying
    // so is the whole point of the dialog.
    guard keyEventMonitor?.start() == true else {
      PermissionAlert.requestRelaunch()
      return
    }
  }

  private func preparationFailed(message: String) {
    preparationFailureMessage = message
    hudController.showMessage(message)
  }
}
