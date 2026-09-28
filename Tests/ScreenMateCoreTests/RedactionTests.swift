import XCTest
@testable import ScreenMateCore

final class RedactionTests: XCTestCase {
    private let redactor = SensitiveTextRedactor()

    func testRedactsAnthropicStyleAPIKey() {
        let result = redactor.redact("export ANTHROPIC_API_KEY=sk-ant-api03-AbCdEf1234567890xyz")
        XCTAssertFalse(result.text.contains("sk-ant-api03"))
        XCTAssertTrue(result.text.contains(SensitiveTextRedactor.placeholder))
        XCTAssertTrue(result.findings.contains(RedactionFinding(category: .apiKey, count: 1)))
    }

    func testRedactsAWSAccessKeyAndGitHubToken() {
        let result = redactor.redact("AKIAIOSFODNN7EXAMPLE and ghp_1234567890abcdefghijklmnopqrstuv")
        XCTAssertFalse(result.text.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(result.text.contains("ghp_1234567890"))
        XCTAssertEqual(result.findings.first(where: { $0.category == .apiKey })?.count, 2)
    }

    func testRedactsPrivateKeyBlock() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEogIBAAKCAQEA1234567890
        abcdefghijklmnop
        -----END RSA PRIVATE KEY-----
        """
        let result = redactor.redact("Here is the key:\n\(pem)\nDone.")
        XCTAssertFalse(result.text.contains("MIIEogIBAAKCAQEA"))
        XCTAssertTrue(result.text.contains("Done."))
        XCTAssertEqual(result.findings.first(where: { $0.category == .privateKey })?.count, 1)
    }

    func testRedactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let result = redactor.redact("Authorization uses \(jwt) today")
        XCTAssertFalse(result.text.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertEqual(result.findings.first(where: { $0.category == .bearerToken })?.count, 1)
    }

    func testRedactsPasswordAssignment() {
        let result = redactor.redact("db password: hunter2sekrit\nother: fine")
        XCTAssertFalse(result.text.contains("hunter2sekrit"))
        XCTAssertTrue(result.text.contains("other: fine"))
        XCTAssertEqual(result.findings.first(where: { $0.category == .passwordAssignment })?.count, 1)
    }

    func testRedactsLuhnValidCardNumber() {
        // A well-known Visa test number.
        let result = redactor.redact("Card 4111 1111 1111 1111 expires 12/28")
        XCTAssertFalse(result.text.contains("4111"))
        XCTAssertEqual(result.findings.first(where: { $0.category == .paymentCard })?.count, 1)
    }

    func testLeavesLongNonLuhnNumberAlone() {
        // An order number of card-like length that fails the checksum.
        let text = "Order 1234567890123 shipped"
        XCTAssertFalse(SensitiveTextRedactor.passesLuhn("1234567890123"))
        let result = redactor.redact(text)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testRedactsSocialSecurityNumber() {
        let result = redactor.redact("SSN 123-45-6789 on file")
        XCTAssertFalse(result.text.contains("123-45-6789"))
    }

    func testOrdinaryTextIsUntouched() {
        let text = """
        The build failed in ChatViewModel.swift at line 42 with
        "cannot convert value of type 'String' to expected argument type 'Int'".
        """
        let result = redactor.redact(text)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.didRedact)
    }

    func testEmptyStringIsSafe() {
        let result = redactor.redact("")
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.didRedact)
    }

    func testSummaryReadsAsASentence() {
        let summary = RedactionFinding.summary([
            RedactionFinding(category: .apiKey, count: 1),
            RedactionFinding(category: .paymentCard, count: 2),
        ])
        XCTAssertEqual(summary, "Removed 1 API key and 2 payment card numbers before sending.")
    }

    func testSummaryOfNothingIsEmpty() {
        XCTAssertEqual(RedactionFinding.summary([]), "")
    }
}

final class SensitiveAppPolicyTests: XCTestCase {
    private let policy = SensitiveAppPolicy()

    func testBlocksPasswordManagerByBundleIdentifier() {
        let decision = policy.evaluate(
            bundleIdentifier: "com.1password.1password",
            windowTitle: "Personal",
            appName: "1Password"
        )
        XCTAssertTrue(decision.isBlocked)
        XCTAssertEqual(
            decision.reason,
            "ScreenMate does not capture 1Password, because it usually shows credentials. You can turn this guard off in Settings › Privacy."
        )
    }

    func testBlocksOnWindowTitleFragment() {
        let decision = policy.evaluate(
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Change your password — Example Bank",
            appName: "Safari"
        )
        XCTAssertTrue(decision.isBlocked)
        XCTAssertEqual(decision.reason?.contains("\"password\""), true)
    }

    func testAllowsOrdinaryWindow() {
        let decision = policy.evaluate(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "ChatViewModel.swift",
            appName: "Xcode"
        )
        XCTAssertFalse(decision.isBlocked)
        XCTAssertNil(decision.reason)
    }

    func testGuardCanBeDisabled() {
        let decision = policy.evaluate(
            bundleIdentifier: "com.1password.1password",
            windowTitle: "Personal",
            appName: "1Password",
            isEnabled: false
        )
        XCTAssertFalse(decision.isBlocked)
    }

    func testMissingMetadataIsAllowedRatherThanCrashing() {
        let decision = policy.evaluate(bundleIdentifier: nil, windowTitle: nil, appName: nil)
        XCTAssertFalse(decision.isBlocked)
    }
}
