import Foundation

struct DailyCostEntry: Identifiable, Codable {
    let id: String
    let date: Date
    let costUSD: Double
    let totalTokens: Int
    var costIsComplete: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, date, costUSD, totalTokens, costIsComplete
    }
}

extension DailyCostEntry {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.date = try container.decode(Date.self, forKey: .date)
        self.costUSD = try container.decode(Double.self, forKey: .costUSD)
        self.totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        self.costIsComplete = try container.decodeIfPresent(Bool.self, forKey: .costIsComplete) ?? true
    }
}

struct LocalCostSummary: Codable {
    var todayCostUSD: Double
    var todayTokens: Int
    var last30DaysCostUSD: Double
    var last30DaysTokens: Int
    var lifetimeCostUSD: Double
    var lifetimeTokens: Int
    var dailyEntries: [DailyCostEntry]
    var updatedAt: Date?
    var todayCostIsComplete: Bool = true
    var last30DaysCostIsComplete: Bool = true
    var lifetimeCostIsComplete: Bool = true
    var source: String? = nil
    var bucketTimeZoneIdentifier: String? = nil
    var historicalModels: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case todayCostUSD, todayTokens, last30DaysCostUSD, last30DaysTokens
        case lifetimeCostUSD, lifetimeTokens, dailyEntries, updatedAt
        case todayCostIsComplete, last30DaysCostIsComplete, lifetimeCostIsComplete
        case source, bucketTimeZoneIdentifier, historicalModels
    }

    static let empty = LocalCostSummary(
        todayCostUSD: 0,
        todayTokens: 0,
        last30DaysCostUSD: 0,
        last30DaysTokens: 0,
        lifetimeCostUSD: 0,
        lifetimeTokens: 0,
        dailyEntries: [],
        updatedAt: nil
    )
}

extension LocalCostSummary {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.todayCostUSD = try container.decode(Double.self, forKey: .todayCostUSD)
        self.todayTokens = try container.decode(Int.self, forKey: .todayTokens)
        self.last30DaysCostUSD = try container.decode(Double.self, forKey: .last30DaysCostUSD)
        self.last30DaysTokens = try container.decode(Int.self, forKey: .last30DaysTokens)
        self.lifetimeCostUSD = try container.decode(Double.self, forKey: .lifetimeCostUSD)
        self.lifetimeTokens = try container.decode(Int.self, forKey: .lifetimeTokens)
        self.dailyEntries = try container.decode([DailyCostEntry].self, forKey: .dailyEntries)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.todayCostIsComplete = try container.decodeIfPresent(Bool.self, forKey: .todayCostIsComplete) ?? true
        self.last30DaysCostIsComplete = try container.decodeIfPresent(Bool.self, forKey: .last30DaysCostIsComplete) ?? true
        self.lifetimeCostIsComplete = try container.decodeIfPresent(Bool.self, forKey: .lifetimeCostIsComplete) ?? true
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.bucketTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .bucketTimeZoneIdentifier)
        self.historicalModels = try container.decodeIfPresent([String].self, forKey: .historicalModels)
    }
}
