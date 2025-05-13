// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "DiscordSocialKit",
	platforms: [
		.iOS(.v17),
		.macOS(.v14),
	],
	swiftLanguageModes: [.v5],
	products: [
		.library(
			name: "DiscordSocialKit",
			targets: ["DiscordSocialKit"])
	],
	dependencies: [
		.package(url: "https://github.com/rryam/MusadoraKit", from: "6.1.0")
	],
	targets: [
		.target(
			name: "DiscordSocialKit",
			dependencies: [
				"MusadoraKit",
				"discord_partner_sdk",
			]),
		.binaryTarget(
			name: "discord_partner_sdk",
			path: "Frameworks/discord_partner_sdk.xcframework"
		),
		.testTarget(
			name: "DiscordSocialKitTests",
			dependencies: ["DiscordSocialKit"]
		),
	]
)
