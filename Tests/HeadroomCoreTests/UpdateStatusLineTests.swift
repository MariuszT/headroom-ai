import Testing
import Foundation
@testable import HeadroomCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
}

@Test func nothingIsSaidBeforeTheFirstCheck() {
    #expect(UpdateStatusLine.text(for: .notChecked, currentVersion: "1.3.0") == nil)
}

@Test func aCheckInFlightSaysSo() {
    #expect(UpdateStatusLine.text(for: .checking, currentVersion: "1.3.0") == "Checking…")
}

/// Names the running version and when it was confirmed, so "up to date" can
/// be told apart from "up to date as of yesterday".
@Test func upToDateNamesTheVersionAndTheTime() {
    let text = UpdateStatusLine.text(
        for: .checked(.upToDate, at: at(24, 10, 42)),
        currentVersion: "1.3.0", now: at(24, 11, 0), calendar: utc
    )
    #expect(text == "You're up to date (1.3.0) · checked 10:42")
}

@Test func anOlderCheckAlsoNamesTheDay() {
    let text = UpdateStatusLine.text(
        for: .checked(.upToDate, at: at(23, 22, 5)),
        currentVersion: "1.3.0", now: at(24, 9, 0), calendar: utc
    )
    #expect(text == "You're up to date (1.3.0) · checked 23 Sep 22:05")
}

@Test func aNewerReleaseIsNamed() {
    let update = AvailableUpdate(version: "1.4.0", url: URL(string: "https://example.invalid")!)
    #expect(UpdateStatusLine.text(for: .checked(.available(update), at: at(24, 10, 0)), currentVersion: "1.3.0")
        == "Headroom AI 1.4.0 is available")
}

@Test func noAnswerIsNotDressedUpAsUpToDate() {
    #expect(UpdateStatusLine.text(for: .checked(.failed, at: at(24, 10, 0)), currentVersion: "1.3.0")
        == "Couldn't reach GitHub.")
}

@Test func theAutomaticCheckRunsEveryThreeHours() {
    #expect(UpdateChecker.automaticInterval == 3 * 3600)
    #expect(UpdateStatusLine.schedule == "Checked automatically at launch and every 3 hours.")
}
