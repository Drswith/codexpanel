import Foundation
import XCTest

final class RateLimitResetCreditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUsagePayloadParsesAvailableResetCount() {
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseAvailableCount(
                ["rate_limit_reset_credits": ["available_count": 3]]
            ),
            3
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseAvailableCount(
                ["rate_limit_reset_credits": ["available_count": -1]]
            ),
            0
        )
    }

    func testCreditsSnapshotParsesDetailsAndFiltersRedeemedOrExpiredCredits() {
        let snapshot = RateLimitResetCreditPolicy.parseCreditsSnapshot(
            [
                "available_count": 2,
                "credits": [
                    [
                        "id": "credit-available",
                        "title": "  Full reset  ",
                        "status": " available ",
                        "granted_at": self.now.addingTimeInterval(-86_400).timeIntervalSince1970,
                        "expires_at": self.now.addingTimeInterval(86_400).timeIntervalSince1970,
                    ],
                    [
                        "id": "credit-expired",
                        "status": "available",
                        "expires_at": self.now.addingTimeInterval(-1).timeIntervalSince1970,
                    ],
                    [
                        "id": "credit-redeemed",
                        "status": "redeemed",
                        "expires_at": self.now.addingTimeInterval(3_600).timeIntervalSince1970,
                    ],
                ],
            ]
        )

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.map(\.id), ["credit-available", "credit-expired", "credit-redeemed"])
        XCTAssertEqual(snapshot.credits.first?.title, "Full reset")
        XCTAssertEqual(snapshot.availableCredits(now: self.now).map(\.id), ["credit-available"])
    }

    func testAccountAvailabilityRequiresAvailableStatusAndUnexpiredDate() {
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct-alice",
            rateLimitResetAvailableCount: 3,
            rateLimitResetCredits: [
                self.credit(id: "available", expiresAt: self.now.addingTimeInterval(3_600)),
                self.credit(id: "expired", expiresAt: self.now.addingTimeInterval(-1)),
                self.credit(id: "redeemed", status: "redeemed", expiresAt: self.now.addingTimeInterval(3_600)),
                self.credit(id: "no-expiry", expiresAt: nil),
            ]
        )

        XCTAssertEqual(
            account.availableRateLimitResetCredits(now: self.now).map(\.id),
            ["available", "no-expiry"]
        )
    }

    func testPresentationSortsByExpiryAndCollapsesToSoonestCredit() {
        let accounts = [
            self.makeAccount(
                id: "acct-later",
                email: "later@example.com",
                credits: [self.credit(id: "later", expiresAt: self.now.addingTimeInterval(86_400))]
            ),
            self.makeAccount(
                id: "acct-sooner",
                email: "sooner@example.com",
                credits: [self.credit(id: "sooner", expiresAt: self.now.addingTimeInterval(3_600))]
            ),
        ]

        let items = RateLimitResetCreditPresentation.items(from: accounts, now: self.now)
        XCTAssertEqual(items.map(\.creditId), ["sooner", "later"])
        XCTAssertEqual(RateLimitResetCreditPresentation.soonest(from: accounts, now: self.now)?.creditId, "sooner")
        XCTAssertEqual(RateLimitResetCreditPresentation.collapsedItems(items).map(\.creditId), ["sooner"])
        XCTAssertTrue(RateLimitResetCreditPresentation.canExpand(items))
    }

    func testPresentationBadgeUsesSoonestExpiry() {
        let account = self.makeAccount(
            id: "acct-badge",
            email: "badge@example.com",
            credits: [self.credit(id: "badge", expiresAt: self.now.addingTimeInterval(48 * 3_600))]
        )

        XCTAssertEqual(RateLimitResetCreditPresentation.badge(from: [account], now: self.now), .approaching)

        let urgent = self.makeAccount(
            id: "acct-urgent",
            email: "urgent@example.com",
            credits: [self.credit(id: "urgent", expiresAt: self.now.addingTimeInterval(2 * 3_600))]
        )
        XCTAssertEqual(RateLimitResetCreditPresentation.badge(from: [urgent], now: self.now), .urgent)

        let farAway = self.makeAccount(
            id: "acct-far",
            email: "far@example.com",
            credits: [self.credit(id: "far", expiresAt: self.now.addingTimeInterval(4 * 86_400))]
        )
        XCTAssertEqual(RateLimitResetCreditPresentation.badge(from: [farAway], now: self.now), .none)
    }

    func testPendingNotificationsHonorTwentyFourHourHorizonAndDeduplication() {
        let account = self.makeAccount(
            id: "acct-notification",
            email: "notification@example.com",
            credits: [
                self.credit(id: "urgent", expiresAt: self.now.addingTimeInterval(2 * 3_600)),
                self.credit(id: "later", expiresAt: self.now.addingTimeInterval(48 * 3_600)),
            ]
        )
        let alreadyNotified = Set([
            RateLimitResetCreditPolicy.notificationKey(
                creditId: "urgent",
                expiresAt: self.now.addingTimeInterval(2 * 3_600)
            ),
        ])

        XCTAssertTrue(
            RateLimitResetCreditPresentation.pendingNotificationKeys(
                from: [account],
                now: self.now,
                alreadyNotified: alreadyNotified
            ).isEmpty
        )
        XCTAssertEqual(
            RateLimitResetCreditPresentation.pendingNotificationKeys(
                from: [account],
                now: self.now,
                alreadyNotified: []
            ).map(\.creditId),
            ["urgent"]
        )
    }

    func testConsumeResultParsesAllKnownCodesAndWindowCount() {
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "reset", "windows_reset": 2]),
            RateLimitResetConsumeResult(code: .reset, windowsReset: 2)
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": " nothing_to_reset "]),
            RateLimitResetConsumeResult(code: .nothingToReset, windowsReset: nil)
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "no_credit"]),
            RateLimitResetConsumeResult(code: .noCredit, windowsReset: nil)
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "already_redeemed"]),
            RateLimitResetConsumeResult(code: .alreadyRedeemed, windowsReset: nil)
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "unexpected"]),
            RateLimitResetConsumeResult(code: .unknown, windowsReset: nil)
        )
    }

    func testPresentationFormatsWindowAndConfirmationDetails() {
        XCTAssertEqual(RateLimitResetCreditPresentation.windowLabel(for: 18_000), "5h")
        XCTAssertEqual(RateLimitResetCreditPresentation.windowLabel(for: 604_800), "7d")
        XCTAssertEqual(RateLimitResetCreditPresentation.windowLabel(for: nil), "?")

        let item = RateLimitResetCreditItem(
            accountId: "acct-confirm",
            accountLabel: "confirm@example.com",
            creditId: "confirm",
            title: "Full reset",
            expiresAt: self.now.addingTimeInterval(2 * 3_600 + 15 * 60),
            primaryUsedPercent: 80,
            secondaryUsedPercent: 20,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let message = RateLimitResetCreditPresentation.confirmMessage(for: item, now: self.now)
        XCTAssertTrue(message.contains("confirm@example.com"))
        XCTAssertTrue(message.contains("5h"))
        XCTAssertTrue(message.contains("7d"))
    }

    private func makeAccount(id: String, email: String, credits: [RateLimitResetCredit]) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: id,
            primaryUsedPercent: 10,
            secondaryUsedPercent: 20,
            rateLimitResetAvailableCount: credits.filter(\.isAvailable).count,
            rateLimitResetCredits: credits
        )
    }

    private func credit(
        id: String,
        status: String = "available",
        expiresAt: Date?
    ) -> RateLimitResetCredit {
        RateLimitResetCredit(
            id: id,
            title: "Full reset",
            status: status,
            grantedAt: self.now.addingTimeInterval(-3_600),
            expiresAt: expiresAt
        )
    }
}
