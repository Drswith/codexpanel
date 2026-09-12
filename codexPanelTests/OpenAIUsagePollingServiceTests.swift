import Foundation
import XCTest

final class OpenAIUsagePollingServiceTests: XCTestCase {
    func testPolicyRefreshesAllAccountsWhenNeverRefreshed() {
        XCTAssertTrue(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: nil,
                now: Date(timeIntervalSince1970: 100),
                interval: 300,
                force: false
            )
        )
    }

    func testPolicyRefreshesAllAccountsAtFiveMinuteBoundary() {
        let lastRefresh = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: lastRefresh,
                now: Date(timeIntervalSince1970: 399),
                interval: 300,
                force: false
            )
        )
        XCTAssertTrue(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: lastRefresh,
                now: Date(timeIntervalSince1970: 400),
                interval: 300,
                force: false
            )
        )
    }

    func testPolicyForceRefreshesAllAccountsImmediately() {
        XCTAssertTrue(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 101),
                interval: 300,
                force: true
            )
        )
    }

    func testPolicyRefreshesStaleActiveOAuthAccount() {
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertEqual(result?.accountId, account.accountId)
    }

    func testPolicySkipsFreshOAuthSnapshot() {
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 40)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }

    func testPolicySkipsCompatibleProvider() {
        let provider = CodexPanelProvider(
            id: "custom-openai",
            kind: .openAICompatible,
            label: "Custom"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }

    func testPolicySkipsExpiredAccount() {
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0),
            tokenExpired: true
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }
}
