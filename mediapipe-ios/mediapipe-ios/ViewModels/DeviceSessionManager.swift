/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import Observation
import SwiftUI

/// Manages DeviceSession lifecycle with 1:1 device-to-session mapping.
/// Monitors device availability and creates sessions on demand via `getSession()`.
@Observable
@MainActor
final class DeviceSessionManager {
  private(set) var hasActiveDevice: Bool = false

  private nonisolated static let sessionStartTimeout: Duration = .seconds(30)

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var sessionGeneration = 0
  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var stateObserverTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    startDeviceMonitoring()
  }

  isolated deinit {
    deviceMonitorTask?.cancel()
    stateObserverTask?.cancel()
    deviceSession?.stop()
  }

  func stopCurrentSession() {
    sessionGeneration += 1
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
  }

  func stopSessionIfCurrent(_ session: DeviceSession) {
    guard deviceSession === session else { return }
    stopCurrentSession()
  }

  /// Stops the device session and cancels monitoring. Call before releasing.
  func cleanup() {
    sessionGeneration += 1
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
    hasActiveDevice = false
  }

  /// Returns a ready DeviceSession, creating one if needed.
  /// Waits for the session to reach .started state before returning.
  func getSession() async throws(DeviceSessionError) -> DeviceSession {
    if deviceMonitorTask == nil { startDeviceMonitoring() }
    let generation = sessionGeneration
    if let session = deviceSession, session.state == .started {
      return session
    }

    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    // Wait for an in-progress session to finish starting
    if let session = deviceSession {
      // The session may have already transitioned to .started before the
      // for-await loop begins iterating (stateStream doesn't buffer past events).
      if session.state == .started {
        startStateObserver(for: session)
        return session
      }

      do throws(DeviceSessionError) {
        try await waitForSessionStart(
          stateStream: session.stateStream(),
          errorStream: session.errorStream()
        )
        guard sessionGeneration == generation, deviceSession === session, !Task.isCancelled else {
          throw .unexpectedError(description: "The session start was cancelled")
        }
        startStateObserver(for: session)
        return session
      } catch {
        if sessionGeneration == generation { stopSessionIfCurrent(session) }
        throw error
      }
    }

    // Create a new session
    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()
      try session.start()

      // The session may have already transitioned to .started before the
      // for-await loop begins iterating (the state change is delivered on
      // another thread and the stream does not buffer past events).
      if session.state == .started {
        startStateObserver(for: session)
        return session
      }

      try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
      guard sessionGeneration == generation, deviceSession === session, !Task.isCancelled else {
        throw .unexpectedError(description: "The session start was cancelled")
      }
      startStateObserver(for: session)
      return session
    } catch {
      guard sessionGeneration == generation else { throw error }
      // A session that never reached .started must not stay alive in the background.
      deviceSession?.stop()
      deviceSession = nil
      throw error
    }
  }

  // MARK: - Private

  private func waitForSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws(DeviceSessionError) {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in stateStream {
            if state == .started {
              return
            }
            if state == .stopped {
              throw DeviceSessionError.unexpectedError(description: "The session failed to start")
            }
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        group.addTask {
          for await error in errorStream {
            throw error
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        group.addTask {
          try await Task.sleep(for: Self.sessionStartTimeout)
          throw DeviceSessionError.unexpectedError(
            description: "Timed out waiting for the glasses session to start")
        }

        guard try await group.next() != nil else {
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }
        group.cancelAll()
      }
    } catch let error as DeviceSessionError {
      throw error
    } catch {
      throw .unexpectedError(description: error.localizedDescription)
    }
  }

  /// Monitors device availability only — does NOT create sessions.
  /// Session creation is deferred to `getSession()` to avoid races.
  private func startDeviceMonitoring() {
    // Capture the selector, not self, so this loop does not keep the manager alive.
    deviceMonitorTask = Task { [weak self, deviceSelector] in
      for await device in deviceSelector.activeDeviceStream() {
        guard !Task.isCancelled, let self else { return }
        hasActiveDevice = device != nil
      }
    }
  }

  private func startStateObserver(for session: DeviceSession) {
    stateObserverTask?.cancel()
    stateObserverTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard !Task.isCancelled, let self, self.deviceSession === session else { return }
        if state == .stopped {
          // DeviceSession.stopped is terminal - clean up
          deviceSession = nil
          return
        }
      }
    }
  }
}
