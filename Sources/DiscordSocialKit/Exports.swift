//
//  Exports.swift
//  DiscordSocialKit
//
//  Created by Adrian Castro on 13/5/25.
//

import Foundation
import SwiftData

// Re-export the DiscordToken model to make it visible when importing the package
@_exported import struct SwiftData.ModelContainer
@_exported import struct SwiftData.ModelContext
@_exported import struct SwiftData.Schema

// Force the DiscordToken class to be exposed publicly
public typealias DiscordTokenModel = DiscordToken
