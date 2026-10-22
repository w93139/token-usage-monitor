import Foundation

struct SubscriptionPreferences {
    let defaults: UserDefaults
    private let anchorKey = "subscription.monthlyAnchor.v1"
    private let legacyKey = "subscription.nextRenewalDate"

    func loadAnchor(calendar: Calendar = .current) -> CalendarDate? {
        if let data = defaults.data(forKey: anchorKey) {
            return try? JSONDecoder().decode(CalendarDate.self, from: data)
        }
        guard let legacy = defaults.object(forKey: legacyKey) as? Date,
              let anchor = CalendarDate(date: legacy, calendar: calendar) else { return nil }
        saveAnchor(anchor)
        return anchor
    }

    func saveAnchor(_ anchor: CalendarDate?) {
        if let anchor, let data = try? JSONEncoder().encode(anchor) { defaults.set(data, forKey: anchorKey) }
        else { defaults.removeObject(forKey: anchorKey) }
        defaults.removeObject(forKey: legacyKey)
    }

}
