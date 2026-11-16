import Foundation
import Testing
@testable import TotalityTasks

@Suite struct QuickAddParserTests {
    private func parse(_ text: String, now: Date = agreed, in calendar: Calendar = denver) -> ParsedTask {
        QuickAddParser.parse(text, now: now, calendar: calendar)
    }

    @Test("The spec's own example: date, time, tag and priority, with the repeat left as typed until step 3")
    func specExample() {
        let text = "Email Dr. Lee about thesis chapter 2 tomorrow 9am #school !high every Monday"
        let parsed = parse(text)
        #expect(parsed.title == "Email Dr. Lee about thesis chapter 2 every Monday")
        #expect(parsed.when == day(2026, 11, 16))
        #expect(parsed.time == TaskTime(hour: 9))
        #expect(parsed.tags == ["school"])
        #expect(parsed.priority == .high)
        #expect(parsed.pieces.map(\.part) == [.when, .time, .tag, .priority])
        #expect(parsed.pieces.map { String(text[$0.range]) } == ["tomorrow", "9am", "#school", "!high"])
    }

    @Test("A deadline is read after due or by, and doesn't plan the day")
    func deadline() {
        let parsed = parse("Draft MUN position paper due Friday")
        #expect(parsed.title == "Draft MUN position paper")
        #expect(parsed.deadline == day(2026, 11, 20))
        #expect(parsed.when == nil)
        #expect(parse("Submit thesis outline by Dec 1").deadline == day(2026, 12, 1))
        // "by" without a date is just a word.
        #expect(parse("Walk by the lake").title == "Walk by the lake")
    }

    @Test("Words that only look like dates or times stay in the title")
    func notDates() {
        for text in ["Read chapter 9", "Ask May about notes", "Sat with Gran", "Enjoy the sun", "Revise section 3.14",
                     "Join the march", "Meet at the library", "Plan next week's menu"] {
            let parsed = parse(text)
            #expect(parsed.title == text, "\(text)")
            #expect(parsed.pieces.isEmpty, "\(text)")
        }
    }

    @Test("Weekdays: plain, this, next and short forms after on")
    func weekdays() {
        // Sunday the 15th.
        #expect(parse("Debate practice Monday").when == day(2026, 11, 16))
        #expect(parse("Debate practice this Sunday").when == day(2026, 11, 15))
        #expect(parse("Debate practice Sunday").when == day(2026, 11, 22))
        // Monday the 16th is in this week, so next Monday is the 23rd.
        #expect(parse("Thesis meeting next Monday").when == day(2026, 11, 23))
        #expect(parse("Call Gran on sat").when == day(2026, 11, 21))
        #expect(parse("Conlang session next week").when == day(2026, 11, 22))
        #expect(parse("Pay rent next month").when == day(2026, 12, 1))
        #expect(parse("Clean the flat this weekend").when == day(2026, 11, 21))
    }

    @Test("Dates written out, in numbers, and counted ahead")
    func writtenDates() {
        #expect(parse("Submit abstract Dec 1").when == day(2026, 12, 1))
        #expect(parse("Submit abstract December 1st").when == day(2026, 12, 1))
        #expect(parse("Submit abstract 1 Dec").when == day(2026, 12, 1))
        // Passed this year, so next year's.
        #expect(parse("Renew passport Jan 5").when == day(2027, 1, 5))
        #expect(parse("Renew passport Jan 5 2028").when == day(2028, 1, 5))
        #expect(parse("Book MUN hotel 11/20").when == day(2026, 11, 20))
        #expect(parse("Book MUN hotel 2027-03-04").when == day(2027, 3, 4))
        #expect(parse("Plan MUN schedule in 2 weeks").when == day(2026, 11, 29))
        #expect(parse("Back up the conlang dictionary in three days").when == day(2026, 11, 18))
        #expect(parse("Nothing on Feb 30").when == nil)
    }

    @Test("Numbers are read in the order the person's region writes dates")
    func regionOrder() {
        let london = calendar("Europe/London", locale: "en_GB")
        #expect(QuickAddParser.parse("Book hotel 4/12", now: agreed, calendar: london).when == day(2026, 12, 4))
        #expect(QuickAddParser.parse("Book hotel 4/12", now: agreed, calendar: denver).when == day(2027, 4, 12))
    }

    @Test("Times with and without am and pm, and a time alone means today")
    func times() {
        #expect(parse("Pay MUN fee at 14:30").time == TaskTime(hour: 14, minute: 30))
        #expect(parse("Pay MUN fee at 14:30").when == day(2026, 11, 15))
        #expect(parse("Print slides 9:30pm").time == TaskTime(hour: 21, minute: 30))
        #expect(parse("Print slides 9 pm").time == TaskTime(hour: 21))
        #expect(parse("Print slides 12am").time == TaskTime(hour: 0))
        #expect(parse("Lunch with Ana at noon").time == .noon)
        // "at 3" is the afternoon; "at 9" the morning.
        #expect(parse("Call advisor tomorrow at 3").time == TaskTime(hour: 15))
        #expect(parse("Call advisor tomorrow at 9").time == TaskTime(hour: 9))
        #expect(parse("Print slides 13pm").time == nil)
    }

    @Test("Evenings, someday and anytime")
    func places() {
        let tonight = parse("Debate prep tonight")
        #expect(tonight.when == day(2026, 11, 15))
        #expect(tonight.isEvening)
        #expect(tonight.title == "Debate prep")
        #expect(parse("Read the Lisbon guide tomorrow evening").isEvening)
        #expect(parse("Learn Toki Pona someday").place == .someday)
        #expect(parse("Learn Toki Pona someday").when == nil)
        #expect(parse("Tidy research folder anytime").place == .anytime)
    }

    @Test("Nested tags, priority marks, and each kind read once")
    func tagsAndPriority() {
        let parsed = parse("Check #school/thesis outline #mun !! #school")
        #expect(parsed.tags == ["school/thesis", "mun", "school"])
        #expect(parsed.priority == .medium)
        #expect(parsed.title == "Check outline")
        let twice = parse("Move debate meeting from Friday to Monday")
        #expect(twice.when == day(2026, 11, 20))
        #expect(twice.title == "Move debate meeting from to Monday")
        #expect(parse("Wrap up !low !high").priority == .low)
    }

    @Test("Punctuation next to a piece goes with it")
    func punctuation() {
        #expect(parse("Call Gran tomorrow, then pack").title == "Call Gran then pack")
        #expect(parse("Call Gran tomorrow.").title == "Call Gran")
    }

    @Test("A pasted list makes one task per line, without its bullets")
    func pastedList() {
        let parsed = QuickAddParser.parseLines(
            "- [ ] Outline chapter 3\n* Email advisor tomorrow\n\n2. Book MUN hotel #mun\n• Pick up gown",
            now: agreed, calendar: denver
        )
        #expect(parsed.map(\.title) == ["Outline chapter 3", "Email advisor", "Book MUN hotel", "Pick up gown"])
        #expect(parsed[1].when == day(2026, 11, 16))
        #expect(parsed[2].tags == ["mun"])
    }

    @Test("Tomorrow is the next day on the person's own clock, whatever the zone")
    func zones() {
        // 05:30 UTC on the 16th is still the evening of the 15th in Denver, but the afternoon of the 16th in Tokyo.
        let instant = ISO8601DateFormatter().date(from: "2026-11-16T05:30:00Z")!
        #expect(QuickAddParser.parse("Call Gran tomorrow", now: instant, calendar: denver).when == day(2026, 11, 16))
        #expect(QuickAddParser.parse("Call Gran tomorrow", now: instant, calendar: calendar("Asia/Tokyo")).when == day(2026, 11, 17))
        #expect(QuickAddParser.parse("Call Gran today", now: instant, calendar: calendar("Pacific/Kiritimati")).when == day(2026, 11, 16))
    }

    @Test("Days count across a clock change: the day before falling back, and the day it springs forward")
    func daylightSaving() {
        // US clocks fall back on 1 November 2026 and spring forward on 14 March 2027.
        let beforeFallBack = moment(2026, 10, 31, 23, 30)
        #expect(QuickAddParser.parse("Hand in essay tomorrow", now: beforeFallBack, calendar: denver).when == day(2026, 11, 1))
        #expect(QuickAddParser.parse("Hand in essay in 2 days", now: beforeFallBack, calendar: denver).when == day(2026, 11, 2))
        let beforeSpring = moment(2027, 3, 13, 22)
        let early = QuickAddParser.parse("Catch the airport shuttle tomorrow 2:30am", now: beforeSpring, calendar: denver)
        #expect(early.when == day(2027, 3, 14))
        #expect(early.time == TaskTime(hour: 2, minute: 30))
        // 2:30 doesn't exist that night, so it rings at the first moment after, on the same day.
        let rings = day(2027, 3, 14).date(at: TaskTime(hour: 2, minute: 30)!, in: denver)
        #expect(TaskDay(rings, in: denver) == day(2027, 3, 14))
        #expect(denver.component(.hour, from: rings) == 3)
        // Europe changes on a different weekend.
        let berlin = calendar("Europe/Berlin", locale: "de_DE")
        #expect(QuickAddParser.parse("Zug buchen tomorrow", now: moment(2027, 3, 27, 23, 30, in: berlin), calendar: berlin).when == day(2027, 3, 28))
    }
}
