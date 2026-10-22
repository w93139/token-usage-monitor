import Foundation

@main
struct SubscriptionChecks {
    static func main() throws {
        func require(_ value: Bool, _ message: String) { precondition(value, message) }
        func civil(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate { CalendarDate(year: year, month: month, day: day)! }
        func calendar(_ zone: String) -> Calendar {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = TimeZone(identifier: zone)!
            return value
        }
        let shanghai = calendar("Asia/Shanghai")
        let losAngeles = calendar("America/Los_Angeles")
        let expected = civil(2026, 11, 19)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        require(CalendarDate(year: 2026, month: 2, day: 29) == nil, "Reject invalid leap date")
        require(CalendarDate(year: 2026, month: 0, day: 1) == nil, "Reject invalid month")
        require((try? decoder.decode(CalendarDate.self, from: Data(#"{"year":2026,"month":2,"day":29}"#.utf8))) == nil, "Decoder validates stored dates")
        let reloaded = try decoder.decode(CalendarDate.self, from: encoder.encode(expected))
        require(CalendarDate(date: reloaded.date(in: losAngeles)!, calendar: losAngeles) == expected, "Persist calendar day across timezones")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = shanghai.timeZone
        require(CalendarDate(date: expected.date(in: shanghai)!, calendar: buddhist) == expected, "Billing dates remain Gregorian")

        func next(_ anchor: CalendarDate, _ now: CalendarDate, _ zone: Calendar = Calendar.current) -> CalendarDate? {
            guard let value = MonthlyRenewal.next(anchor: anchor, now: now.date(in: zone)!, calendar: zone) else { return nil }
            return CalendarDate(date: value, calendar: zone)
        }
        require(next(civil(2026, 1, 31), civil(2026, 2, 1), shanghai) == civil(2026, 2, 28), "Clamp original Jan 31 to February end")
        require(next(civil(2026, 1, 31), civil(2026, 3, 1), shanghai) == civil(2026, 3, 31), "Original day restored after short month")
        require(next(civil(2028, 1, 31), civil(2028, 2, 1), shanghai) == civil(2028, 2, 29), "Leap month end")
        require(next(civil(2026, 12, 19), civil(2026, 12, 20), shanghai) == civil(2027, 1, 19), "Cross year")
        require(next(civil(2026, 1, 19), civil(2026, 10, 19), shanghai) == civil(2026, 10, 19), "Keep renewal today")
        let lateRenewalDay = shanghai.date(bySettingHour: 23, minute: 59, second: 0, of: civil(2026, 10, 19).date(in: shanghai)!)!
        let sameDay = MonthlyRenewal.next(anchor: civil(2026, 1, 19), now: lateRenewalDay, calendar: shanghai)!
        require(CalendarDate(date: sameDay, calendar: shanghai) == civil(2026, 10, 19), "Renewal remains today after noon")
        require(next(civil(2026, 1, 19), civil(2026, 10, 20), shanghai) == civil(2026, 11, 19), "Advance once today is past renewal")
        require(next(civil(2027, 1, 19), civil(2026, 10, 20), shanghai) == civil(2027, 1, 19), "Preserve future anchor")
        require(next(civil(2026, 1, 8), civil(2026, 3, 8), losAngeles) == civil(2026, 3, 8), "DST spring day")
        require(next(civil(2026, 1, 1), civil(2026, 11, 1), losAngeles) == civil(2026, 11, 1), "DST fall day")
        let suite = "token-monitor-subscription-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SubscriptionPreferences(defaults: defaults)
        require(preferences.loadAnchor(calendar: shanghai) == nil, "Empty settings stay unset")
        defaults.set(civil(2026, 1, 31).date(in: shanghai)!, forKey: "subscription.nextRenewalDate")
        require(preferences.loadAnchor(calendar: shanghai) == civil(2026, 1, 31), "Migrate actual legacy setting")
        require(defaults.object(forKey: "subscription.nextRenewalDate") == nil, "Migration removes legacy value, so clearing cannot resurrect it")
        require(preferences.loadAnchor(calendar: losAngeles) == civil(2026, 1, 31), "Reload after timezone change keeps original day")
        preferences.saveAnchor(nil)
        require(preferences.loadAnchor() == nil, "Clear estimate")
        preferences.saveAnchor(civil(2026, 1, 31))
        require(SubscriptionPreferences(defaults: UserDefaults(suiteName: suite)!).loadAnchor() == civil(2026, 1, 31), "Saved anchor survives a new preferences instance")
        defaults.set(Data("invalid".utf8), forKey: "subscription.monthlyAnchor.v1")
        require(preferences.loadAnchor() == nil, "Corrupt settings do not invent a date")
        preferences.saveAnchor(nil)
        require(preferences.loadAnchor() == nil, "Cleared date stays unset")
        print("Subscription checks passed: month-end, leap-year, DST, timezone, persistence and migration")
    }
}
