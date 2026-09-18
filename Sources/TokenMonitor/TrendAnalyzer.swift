import Foundation

struct DailyCost: Identifiable {
    var id: Date { day }
    let day: Date
    let cost: Double
}

/// 消耗趋势推算。
/// 原理：DeepSeek 只给余额不给用量，所以用「当天起始余额 - 当天结束余额」得到当天消耗。
/// 刷新越勤，曲线越接近真实。
enum TrendAnalyzer {

    static func dailyCosts(snapshots: [BalanceSnapshot],
                           days: Int,
                           calendar: Calendar = .current) -> [DailyCost] {
        guard !snapshots.isEmpty else { return [] }

        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        let todayStart = calendar.startOfDay(for: Date())

        var result: [DailyCost] = []

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            let inDay = sorted.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            let beforeDay = sorted.last { $0.timestamp < dayStart }

            // 起点优先用前一天最后一条快照，保证跨天连续
            let startBalance = beforeDay?.totalBalance ?? inDay.first?.totalBalance
            let endBalance = inDay.last?.totalBalance ?? startBalance

            let cost: Double
            if let s = startBalance, let e = endBalance {
                // 负数说明当天有充值，记为 0 消耗
                cost = max(0, s - e)
            } else {
                cost = 0
            }

            result.append(DailyCost(day: dayStart, cost: cost))
        }
        return result
    }

    /// 今日消耗
    static func todayCost(snapshots: [BalanceSnapshot], calendar: Calendar = .current) -> Double {
        dailyCosts(snapshots: snapshots, days: 1, calendar: calendar).last?.cost ?? 0
    }

    /// 区间消耗合计
    static func totalCost(snapshots: [BalanceSnapshot], days: Int, calendar: Calendar = .current) -> Double {
        dailyCosts(snapshots: snapshots, days: days, calendar: calendar).reduce(0) { $0 + $1.cost }
    }

    /// 近 N 天平均日消耗（只统计有数据的天）
    static func averageDailyCost(snapshots: [BalanceSnapshot], days: Int, calendar: Calendar = .current) -> Double {
        let costs = dailyCosts(snapshots: snapshots, days: days, calendar: calendar).map(\.cost)
        let active = costs.filter { $0 > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0, +) / Double(active.count)
    }

    /// 按当前日均消耗估算余额还能用几天
    static func estimatedDaysRemaining(balance: Double,
                                       snapshots: [BalanceSnapshot],
                                       calendar: Calendar = .current) -> Double? {
        let avg = averageDailyCost(snapshots: snapshots, days: 14, calendar: calendar)
        guard avg > 0, balance > 0 else { return nil }
        return balance / avg
    }
}
