//
//  DiscordSocialKit.swift
//  DiscordSocialKit
//
//  Created by Adrian Castro on 8/5/25.
//

import Combine
import CoreFoundation
import Foundation
internal import MusadoraKit
import SwiftData
import discord_partner_sdk

// Timer utilities at file scope
extension Timer {
	fileprivate static func currentMainThreadTimers() -> [Timer] {
		RunLoop.main.scheduledTimers
	}
}

extension RunLoop {
	fileprivate var scheduledTimers: [Timer] {
		// Safe access to current run loop's timers
		let common = self.description
		return common.isEmpty ? [] : []  // Placeholder - actual timer tracking handled by the actor
	}
}

@MainActor
public final class DiscordManager: ObservableObject {
	@MainActor private var client: UnsafeMutablePointer<Discord_Client>?
	private var applicationId: UInt64
	private var verifier: Discord_AuthorizationCodeVerifier?
	private var modelContext: ModelContext?

	private var artworkCache: [String: URL] = [:]

	@Published public private(set) var isReady = false
	@Published public private(set) var isAuthenticated = false
	@Published public private(set) var errorMessage: String? = nil
	@Published public private(set) var isAuthorizing = false
	@Published public var isRunning = false
	@Published public private(set) var username: String?
	@Published public private(set) var globalName: String?
	@Published public private(set) var userId: UInt64 = 0
	@Published public private(set) var avatarURL: URL?

	private struct UserData {
		var username: String
		var globalName: String?
		var avatarURL: URL?
		var userId: UInt64
	}
	private var cachedUserData: UserData?

	private actor CleanupActor: @unchecked Sendable {
		private struct CleanupData: Sendable {
			struct PointerData: Sendable {
				let address: UInt
			}
			let clientData: PointerData?
			let timerId: ObjectIdentifier?
		}

		private var cleanupData: CleanupData?

		private nonisolated func prepareCleanup(
			client: UnsafeMutablePointer<Discord_Client>?,
			timer: Timer?
		) -> CleanupData {
			CleanupData(
				clientData: client.map { CleanupData.PointerData(address: UInt(bitPattern: $0)) },
				timerId: timer.map(ObjectIdentifier.init)
			)
		}

		// Fix access control to be private
		private func initialize(_ data: CleanupData) {
			cleanupData = data
		}

		// Add a public entry point that takes raw values
		func cleanupResources(
			clientAddress: UInt?,
			timerIdentifier: ObjectIdentifier?
		) async {
			let data = CleanupData(
				clientData: clientAddress.map { CleanupData.PointerData(address: $0) },
				timerId: timerIdentifier
			)

			self.cleanupData = data
			await cleanup()
		}

		func cleanup() async {
			guard let data = cleanupData else { return }

			// Handle timer on main thread
			if let timerId = data.timerId {
				await MainActor.run {
					Timer.currentMainThreadTimers()
						.first { ObjectIdentifier($0) == timerId }?
						.invalidate()
				}
			}

			// Handle client cleanup
			if let clientData = data.clientData,
				let client = UnsafeMutablePointer<Discord_Client>(bitPattern: clientData.address)
			{
				var activity = Discord_Activity()
				Discord_Activity_Init(&activity)
				Discord_Client_UpdateRichPresence(client, &activity, nil, nil, nil)
				Discord_Client_Drop(client)
				client.deallocate()
			}
		}
	}

	public func startPresenceUpdates() {
		print("🎮 Starting Discord Rich Presence")
		isRunning = true
		Task { @MainActor in
			await startUpdates()
		}
	}

	public func stopPresenceUpdates() {
		print("🛑 Stopping Discord Rich Presence")
		isRunning = false
		Task { @MainActor in
			await stopUpdates()
		}
	}

	@MainActor private var updateTimer: Timer?
	private var lastId: String = ""
	private var lastTitle: String = ""
	private var lastArtist: String = ""
	private var lastArtwork: URL? = nil
	private var lastDuration: TimeInterval = 0
	private var lastCurrentTime: TimeInterval = 0

	private var currentPlaybackInfo:
		(
			id: String, title: String, artist: String, duration: TimeInterval,
			currentTime: TimeInterval,
			artworkURL: URL?
		)? = nil
	private let presenceUpdateInterval: TimeInterval = 15

	private func fetchUserInfo() {
		guard let client = client else { return }

		var userHandle = Discord_UserHandle(opaque: nil)
		Discord_Client_GetCurrentUser(client, &userHandle)

		let userId = Discord_UserHandle_Id(&userHandle)
		print("🆔 Got user ID: \(userId)")

		var usernameStr = Discord_String()
		let _ = Discord_UserHandle_Username(&userHandle, &usernameStr)

		let username = {
			if let usernamePtr = usernameStr.ptr {
				return String(
					bytes: UnsafeRawBufferPointer(
						start: usernamePtr,
						count: Int(usernameStr.size)
					),
					encoding: .utf8
				) ?? "Unknown User"
			}
			return "Unknown User"
		}()

		print("👤 Got username: \(username)")

		var displayNameStr = Discord_String()
		let _ = Discord_UserHandle_DisplayName(&userHandle, &displayNameStr)

		let globalName = {
			if let displayNamePtr = displayNameStr.ptr {
				return String(
					bytes: UnsafeRawBufferPointer(
						start: displayNamePtr,
						count: Int(displayNameStr.size)
					),
					encoding: .utf8
				)
			}
			return nil
		}()

		print("📝 Got display name: \(globalName ?? "none")")

		var avatarUrlStr = Discord_String()
		let _ = Discord_UserHandle_AvatarUrl(
			&userHandle,
			Discord_UserHandle_AvatarType_Png,
			Discord_UserHandle_AvatarType_Gif,
			&avatarUrlStr
		)

		let avatarURL = {
			if let urlPtr = avatarUrlStr.ptr {
				let urlString =
					String(
						bytes: UnsafeRawBufferPointer(
							start: urlPtr,
							count: Int(avatarUrlStr.size)
						),
						encoding: .utf8
					) ?? ""
				return URL(string: urlString)
			}
			return nil
		}()

		print("🖼️ Got avatar URL: \(avatarURL?.absoluteString ?? "none")")

		let userData = UserData(
			username: username,
			globalName: globalName,
			avatarURL: avatarURL,
			userId: userId
		)

		Task { @MainActor in
			self.cachedUserData = userData
			self.username = username
			self.globalName = globalName
			self.avatarURL = avatarURL
			self.userId = userId

			print("✅ User info updated in UI")
		}
	}

	private let statusCallback: Discord_Client_OnStatusChanged = {
		status, error, errorDetail, userData in
		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
		print("🔄 Status changed: \(status)")

		Task { @MainActor in
			if error != Discord_Client_Error_None {
				print("❌ Connection Error: \(error) - Details: \(errorDetail)")
				manager.handleError("Connection error \(error): \(errorDetail)")
				return
			}

			switch status {
			case Discord_Client_Status_Ready:
				print("✅ Client is ready!")
				manager.isReady = true
				if manager.username == nil {
					manager.fetchUserInfo()
				}
			case Discord_Client_Status_Connected:
				print("🔗 Client connected!")
				manager.isAuthenticated = true
				manager.isAuthorizing = false
				manager.errorMessage = nil

				if let cached = manager.cachedUserData {
					manager.username = cached.username
					manager.globalName = cached.globalName
					manager.avatarURL = cached.avatarURL
					manager.userId = cached.userId
					print("📋 Restored cached user data")
				}
			case Discord_Client_Status_Disconnected:
				print("❌ Client disconnected")
				manager.isAuthenticated = false
				manager.isReady = false
			default:
				break
			}
		}
	}

	public init(applicationId: UInt64) {
		self.applicationId = applicationId
		setupClient()
	}

	public func setModelContext(_ context: ModelContext) {
		self.modelContext = context
	}

	private func setupClient() {
		print("🚀 Initializing Discord SDK...")

		// Flag to track initialization state
		var isInitialized = false

		self.client = UnsafeMutablePointer<Discord_Client>.allocate(capacity: 1)
		guard let client = self.client else { return }

		Discord_Client_Init(client)
		Discord_Client_SetApplicationId(client, applicationId)

		// Mark as initialized
		isInitialized = true

		let logCallback: Discord_Client_LogCallback = { message, severity, userData in
			// ...existing code...
		}
		Discord_Client_AddLogCallback(client, logCallback, nil, nil, Discord_LoggingSeverity_Info)

		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_SetStatusChangedCallback(client, statusCallback, nil, userDataPtr)

		// Create a serial queue for Discord callbacks to prevent thread safety issues
		let callbackQueue = DispatchQueue(label: "com.discordsocialkit.callbacks")

		// Use an atomic variable to track if callbacks should continue running
		let shouldRunCallbacks = Atomic(value: true)

		callbackQueue.async { [weak self] in
			print("🔄 Starting Discord callback loop")

			while shouldRunCallbacks.value && self != nil {
				autoreleasepool {
					// Guard against crashes with a safety check
					if isInitialized {
						// Wrap in try/catch to prevent crashes
						let result = withoutActuallyEscaping(Discord_RunCallbacks) { callback in
							callback()
							return true
						}

						if !result {
							print("⚠️ Discord callback failed - pausing")
							Thread.sleep(forTimeInterval: 0.1)
						}
					}
				}
				Thread.sleep(forTimeInterval: 0.02)  // Slightly longer delay
			}
			print("🛑 Discord callback loop ended")
		}

		// Store the atomic flag for cleanup
		self.callbackFlag = shouldRunCallbacks

		print("✨ Discord SDK initialized successfully")
	}

	// Simple atomic wrapper
	private class Atomic<T> {
		private let queue = DispatchQueue(label: "com.discordsocialkit.atomic")
		private var _value: T

		init(value: T) {
			self._value = value
		}

		var value: T {
			get {
				return queue.sync { _value }
			}
			set {
				queue.sync { _value = newValue }
			}
		}
	}

	// Add property to store the flag
	private var callbackFlag: Atomic<Bool>?

	public func authorize() {
		guard let client = self.client else { return }
		print("Starting auth flow...")
		isAuthorizing = true

		let verifier = UnsafeMutablePointer<Discord_AuthorizationCodeVerifier>.allocate(capacity: 1)
		Discord_Client_CreateAuthorizationCodeVerifier(client, verifier)
		self.verifier = verifier.pointee

		var args = Discord_AuthorizationArgs()
		Discord_AuthorizationArgs_Init(&args)
		Discord_AuthorizationArgs_SetClientId(&args, applicationId)

		var scopes = Discord_String()
		Discord_Client_GetDefaultPresenceScopes(&scopes)
		Discord_AuthorizationArgs_SetScopes(&args, scopes)

		var challenge = Discord_AuthorizationCodeChallenge()
		Discord_AuthorizationCodeVerifier_Challenge(verifier, &challenge)
		Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)

		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_Authorize(client, &args, self.authCallback, nil, userDataPtr)
	}

	public func clearRichPresence() {
		guard let client = client else { return }
		print("🧹 Clearing rich presence...")

		Discord_Client_ClearRichPresence(client)
	}

	struct RichPresenceContext {
		let namePtr: UnsafeMutablePointer<UInt8>
		let detailsPtr: UnsafeMutablePointer<UInt8>
		let statePtr: UnsafeMutablePointer<UInt8>
		let manager: DiscordManager
	}

	private static let richPresenceCallback:
		@convention(c) (UnsafeMutablePointer<Discord_ClientResult>?, UnsafeMutableRawPointer?) ->
			Void = { result, userData in
				print("📣 Rich Presence callback received")
				guard let contextPtr = userData?.assumingMemoryBound(to: RichPresenceContext.self)
				else {
					print("❌ Rich Presence callback: No context")
					return
				}

				let context = contextPtr.pointee
				defer {
					print("🧹 Cleaning up Rich Presence buffers")
					context.namePtr.deallocate()
					context.detailsPtr.deallocate()
					context.statePtr.deallocate()
					contextPtr.deallocate()
				}

				if let result = result {
					if Discord_ClientResult_Successful(result) {
						print("✅ Rich Presence updated successfully!")
					} else {
						var errorStr = Discord_String()
						Discord_ClientResult_Error(result, &errorStr)
						if let ptr = errorStr.ptr {
							let errorMessage =
								String(
									bytes: UnsafeRawBufferPointer(
										start: ptr,
										count: Int(errorStr.size)
									),
									encoding: .utf8
								) ?? "Unknown error"
							print("❌ Rich Presence update failed: \(errorMessage)")
						} else {
							print("❌ Rich Presence update failed: No error message available")
						}
					}
				} else {
					print("❌ Rich Presence update failed: No result")
				}
			}

	private func validateAssetURL(_ url: URL) -> Bool {
		print("Validating asset URL: \(url)")
		let urlString = url.absoluteString
		return urlString.count >= 1 && urlString.count <= 256
	}

	public func updateRichPresence(
		id: String, title: String, artist: String, duration: TimeInterval,
		currentTime: TimeInterval,
		artworkURL: URL? = nil
	) async {
		guard let client = client else {
			print("⚠️ Cannot update Rich Presence: No client")
			return
		}

		guard isAuthenticated else {
			print("⚠️ Cannot update Rich Presence: Not authenticated")
			return
		}

		if title.isEmpty || artist.isEmpty {
			print("⚠️ Skipping empty rich presence update")
			return
		}

		print("📝 Rich Presence Update Request:")
		print("- Title: \(title)")
		print("- Artist: \(artist)")
		print("- Duration: \(duration)")
		print("- Current Time: \(currentTime)")

		var activity = Discord_Activity()
		Discord_Activity_Init(&activity)

		Discord_Activity_SetType(&activity, Discord_ActivityTypes_Playing)

		var assets = Discord_ActivityAssets()
		Discord_ActivityAssets_Init(&assets)

		if let cachedArtwork = artworkCache[id] {
			var artworkStr = makeDiscordString(from: cachedArtwork.absoluteString)
			var hoverText = makeDiscordString(from: "\(title) by \(artist)")

			Discord_ActivityAssets_SetLargeImage(&assets, &artworkStr)
			Discord_ActivityAssets_SetLargeText(&assets, &hoverText)
		} else {
			do {
				let song = try await MCatalog.song(id: MusicItemID(rawValue: id), fetch: [.albums])
				if let artworkURL = song.albums?.first?.artwork?.url(width: 600, height: 600),
					validateAssetURL(artworkURL)
				{
					artworkCache[id] = artworkURL

					var artworkStr = makeDiscordString(from: artworkURL.absoluteString)
					var hoverText = makeDiscordString(from: "\(title) by \(artist)")

					Discord_ActivityAssets_SetLargeImage(&assets, &artworkStr)
					Discord_ActivityAssets_SetLargeText(&assets, &hoverText)
				}
			} catch {
				print("⚠️ Failed to fetch artwork: \(error)")
			}
		}

		Discord_Activity_SetAssets(&activity, &assets)

		let namePtr = makeStringBuffer(from: "Apple Music").ptr
		var nameStr = Discord_String()
		nameStr.ptr = namePtr
		nameStr.size = Int(Int32(4))
		Discord_Activity_SetName(&activity, nameStr)

		let detailsPtr = makeStringBuffer(from: title).ptr
		var detailsStr = Discord_String()
		detailsStr.ptr = detailsPtr
		detailsStr.size = Int(Int32(title.utf8.count))
		Discord_Activity_SetDetails(&activity, &detailsStr)

		let statePtr = makeStringBuffer(from: "by \(artist)").ptr
		var stateStr = Discord_String()
		stateStr.ptr = statePtr
		stateStr.size = Int(Int32(("by \(artist)").utf8.count))
		Discord_Activity_SetState(&activity, &stateStr)

		var timestamps = Discord_ActivityTimestamps()
		Discord_ActivityTimestamps_Init(&timestamps)

		let now = Date().timeIntervalSince1970
		let startTime = UInt64((now - currentTime) * 1000)
		let endTime = UInt64((now - currentTime + duration) * 1000)

		print("🕒 Setting timestamps: start=\(startTime)ms, end=\(endTime)ms")

		Discord_ActivityTimestamps_SetStart(&timestamps, startTime)
		Discord_ActivityTimestamps_SetEnd(&timestamps, endTime)
		Discord_Activity_SetTimestamps(&activity, &timestamps)

		let context = RichPresenceContext(
			namePtr: namePtr,
			detailsPtr: detailsPtr,
			statePtr: statePtr,
			manager: self
		)
		let contextPtr = UnsafeMutablePointer<RichPresenceContext>.allocate(capacity: 1)
		contextPtr.initialize(to: context)

		print("🎵 Sending activity update to Discord...")
		Discord_Client_UpdateRichPresence(
			client, &activity, Self.richPresenceCallback, nil, contextPtr)
	}

	public func updateCurrentPlayback(
		id: String,
		title: String,
		artist: String,
		duration: TimeInterval,
		currentTime: TimeInterval,
		artworkURL: URL?
	) {
		currentPlaybackInfo = (id, title, artist, duration, currentTime, artworkURL)
	}

	public func clearPlayback() {
		currentPlaybackInfo = nil
		artworkCache.removeAll()
		clearRichPresence()
	}

	private func makeStringBuffer(from string: String) -> (
		ptr: UnsafeMutablePointer<UInt8>, size: Int32
	) {
		let data = Array(string.utf8) + [0]
		let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		ptr.initialize(from: data, count: data.count)
		return (ptr, Int32(string.utf8.count))
	}

	private func makeDiscordString(from string: String) -> Discord_String {
		var discordStr = Discord_String()
		let buffer = makeStringBuffer(from: string)
		discordStr.ptr = buffer.ptr
		discordStr.size = Int(buffer.size)
		return discordStr
	}

	private func updateStoredToken(
		accessToken: String, refreshToken: String, expiresIn: TimeInterval
	) async {
		await MainActor.run {
			guard let context = modelContext else {
				print("❌ No ModelContext available")
				return
			}

			do {
				print("💾 Saving new token...")

				let descriptor = FetchDescriptor<DiscordToken>()
				let existingTokens = try context.fetch(descriptor)
				for token in existingTokens {
					print("🗑️ Removing old token: \(token.tokenId)")
					context.delete(token)
				}

				let token = DiscordToken(
					accessToken: accessToken,
					refreshToken: refreshToken,
					expiresIn: expiresIn
				)

				context.insert(token)
				try context.save()

				print("✅ Token saved successfully")
				print("- ID: \(token.tokenId)")
				print("- Expires: \(String(describing: token.expiresAt))")
			} catch {
				print("❌ Failed to save token: \(error)")
				print("Error details: \(error.localizedDescription)")
			}
		}
	}

	private func loadExistingToken() -> DiscordToken? {
		guard let context = modelContext else {
			print("❌ Cannot load token: No ModelContext available")
			return nil
		}

		var descriptor = FetchDescriptor<DiscordToken>()
		descriptor.sortBy = [SortDescriptor(\DiscordToken.expiresAt, order: .reverse)]
		descriptor.fetchLimit = 1

		do {
			let tokens = try context.fetch(descriptor)
			print("🔍 Found \(tokens.count) tokens in store")
			return tokens.first
		} catch {
			print("❌ Failed to fetch tokens: \(error)")
			return nil
		}
	}

	private func refreshRichPresence() {
		Task {
			await updateRichPresence(
				id: lastId,
				title: lastTitle,
				artist: lastArtist,
				duration: lastDuration,
				currentTime: lastCurrentTime,
				artworkURL: lastArtwork
			)
		}
	}

	private func stopUpdates() async {
		print("⏹️ Stopping presence updates")
		updateTimer?.invalidate()
		updateTimer = nil

		currentPlaybackInfo = nil
		lastTitle = ""
		lastArtist = ""
		lastArtwork = nil
		lastDuration = 0
		lastCurrentTime = 0

		clearRichPresence()
	}

	private func startUpdates() async {
		await stopUpdates()

		print("▶️ Starting presence updates")
		updateTimer = Timer.scheduledTimer(withTimeInterval: presenceUpdateInterval, repeats: true)
		{ [weak self] _ in
			guard let self = self else { return }
			Task { @MainActor in
				guard let info = self.currentPlaybackInfo,
					self.isAuthenticated,
					self.isReady,
					self.isRunning
				else { return }

				await self.updateRichPresence(
					id: info.id,
					title: info.title,
					artist: info.artist,
					duration: info.duration,
					currentTime: info.currentTime,
					artworkURL: info.artworkURL
				)
			}
		}
	}

	private func handleError(_ message: String) {
		DispatchQueue.main.async {
			self.errorMessage = message
			self.isReady = false
			self.isAuthenticated = false
			self.isAuthorizing = false
		}
	}

	public func refreshTokenIfNeeded() async {
		guard let token = loadExistingToken(),
			let refreshToken = token.refreshToken,
			token.needsRefresh
		else {
			print("⚠️ No valid refresh token available")
			return
		}
		let refreshStr = makeDiscordString(from: refreshToken)

		print("🔄 Refreshing token using refresh token")
		Discord_Client_RefreshToken(
			client,
			applicationId,
			refreshStr,
			tokenCallback,
			nil,
			Unmanaged.passRetained(self).toOpaque()
		)
	}

	public func setupWithExistingToken() async {
		await MainActor.run {
			guard let token = loadExistingToken(),
				let accessToken = token.accessToken
			else {
				print("⚠️ No existing token found or token invalid")
				return
			}

			if token.needsRefresh {
				print("🔄 Token needs refresh, initiating refresh flow")
				Task { await refreshTokenIfNeeded() }
			} else {
				print("✅ Using existing valid token")
				let accessStr = makeDiscordString(from: accessToken)
				Discord_Client_UpdateToken(
					client,
					Discord_AuthorizationTokenType_Bearer,
					accessStr,
					{ _, userData in
						guard let userData = userData else { return }
						let manager = Unmanaged<DiscordManager>.fromOpaque(userData)
							.takeUnretainedValue()
						Discord_Client_Connect(manager.client)
					},
					nil,
					Unmanaged.passRetained(self).toOpaque()
				)
			}
		}
	}

	private let tokenCallback: Discord_Client_TokenExchangeCallback = {
		result, token, refreshToken, tokenType, expiresIn, scope, userData in

		// Create Sendable token data
		struct TokenData: Sendable {
			let accessToken: String
			let refreshToken: String
			let expiresIn: TimeInterval
			let userDataPointer: UInt

			init?(
				token: Discord_String,
				refreshToken: Discord_String,
				expiresIn: Int32,
				userData: UnsafeMutableRawPointer?
			) {
				guard let userData = userData,
					let tokenPtr = token.ptr,
					let refreshPtr = refreshToken.ptr,
					let tokenStr = String(
						bytes: UnsafeRawBufferPointer(start: tokenPtr, count: Int(token.size)),
						encoding: .utf8),
					let refreshStr = String(
						bytes: UnsafeRawBufferPointer(
							start: refreshPtr, count: Int(refreshToken.size)),
						encoding: .utf8)
				else {
					return nil
				}

				self.accessToken = tokenStr
				self.refreshToken = refreshStr
				self.expiresIn = TimeInterval(expiresIn)  // Convert Int32 to TimeInterval
				self.userDataPointer = UInt(bitPattern: userData)
			}

			var userDataRaw: UnsafeMutableRawPointer {
				UnsafeMutableRawPointer(bitPattern: userDataPointer)!
			}
		}

		guard
			let tokenData = TokenData(
				token: token,
				refreshToken: refreshToken,
				expiresIn: expiresIn,
				userData: userData
			)
		else {
			print("❌ Failed to parse token data from Discord")
			return
		}

		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
		print("🎟️ Received new token from Discord")

		// Use Task for async work
		Task { @MainActor [weak manager, tokenData] in
			guard let manager = manager else { return }

			// First save the token
			await manager.updateStoredToken(
				accessToken: tokenData.accessToken,
				refreshToken: tokenData.refreshToken,
				expiresIn: tokenData.expiresIn
			)

			// Then update client with the token
			print("🔑 Updating client with new token...")
			var accessStr = manager.makeDiscordString(from: tokenData.accessToken)

			// Use the native C API to update token and connect
			Discord_Client_UpdateToken(
				manager.client,
				Discord_AuthorizationTokenType_Bearer,
				accessStr,
				{ _, innerUserData in
					guard let innerUserData = innerUserData else { return }
					let innerManager = Unmanaged<DiscordManager>.fromOpaque(innerUserData)
						.takeUnretainedValue()
					print("🔌 Connecting with new token...")
					Discord_Client_Connect(innerManager.client)
				},
				nil,
				tokenData.userDataRaw  // Use the captured userData
			)
		}
	}

	private let authCallback: Discord_Client_AuthorizationCallback = {
		result, code, redirectUri, userData in

		// Create Sendable wrapper for auth data
		struct AuthData: Sendable {
			struct AuthStrings: Sendable {
				let code: String
				let uri: String
			}
			let resultSuccess: Bool
			let strings: AuthStrings
			// Store user data pointer as numeric value for safety
			let userDataPointer: UInt

			init?(
				result: UnsafeMutablePointer<Discord_ClientResult>?,
				code: Discord_String,
				uri: Discord_String,
				userData: UnsafeMutableRawPointer?
			) {
				guard let result = result,
					let userData = userData
				else { return nil }

				self.resultSuccess = Discord_ClientResult_Successful(result)
				self.userDataPointer = UInt(bitPattern: userData)

				// Copy strings to ensure thread safety
				self.strings = AuthStrings(
					code: String(
						bytes: UnsafeRawBufferPointer(
							start: code.ptr,
							count: Int(code.size)
						),
						encoding: .utf8
					) ?? "",
					uri: String(
						bytes: UnsafeRawBufferPointer(
							start: uri.ptr,
							count: Int(uri.size)
						),
						encoding: .utf8
					) ?? ""
				)
			}

			var userDataRaw: UnsafeMutableRawPointer {
				UnsafeMutableRawPointer(bitPattern: userDataPointer)!
			}
		}

		guard
			let authData = AuthData(
				result: result,
				code: code,
				uri: redirectUri,
				userData: userData
			)
		else { return }

		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()

		Task { @MainActor [weak manager, authData] in
			guard let manager = manager else { return }

			guard var verifier = manager.verifier else {
				manager.handleError("❌ Authentication Error: No verifier available")
				return
			}

			var localVerifierStr = Discord_String()
			Discord_AuthorizationCodeVerifier_Verifier(&verifier, &localVerifierStr)

			if !authData.resultSuccess {
				manager.handleError("Authentication failed")
				return
			}

			// Create Discord strings from copied data
			var codeStr = manager.makeDiscordString(from: authData.strings.code)
			var uriStr = manager.makeDiscordString(from: authData.strings.uri)

			Discord_Client_GetToken(
				manager.client,
				manager.applicationId,
				codeStr,
				localVerifierStr,
				uriStr,
				manager.tokenCallback,
				nil,
				authData.userDataRaw  // Use Sendable-safe user data
			)
		}
	}

	// Static helper for cleanup to avoid capturing self
	@MainActor
	private static func performCleanup(
		for manager: DiscordManager,
		with actor: CleanupActor
	) {
		// Extract values while we have access to the manager
		let clientAddress = manager.client.map { UInt(bitPattern: $0) }
		let timerIdentifier = manager.updateTimer.map { ObjectIdentifier($0) }

		// Schedule cleanup without capturing manager
		Task.detached {
			await actor.cleanupResources(
				clientAddress: clientAddress,
				timerIdentifier: timerIdentifier
			)
		}
	}

	deinit {
		// Stop callbacks before cleanup
		callbackFlag?.value = false

		let actor = CleanupActor()

		// Use unowned self to indicate we don't extend lifetime
		Task { @MainActor [unowned self, actor] in
			// Use static method to avoid capturing self in nested task
			Self.performCleanup(for: self, with: actor)
		}
	}
}
