import SwiftUI
import Charts

struct TrendView: View {
    @EnvironmentObject var state: AppState
    @LocalState private var range: Int = 7

    var body: some View {
        Group {
            if let account = state.selectedAccount {
                content(for: account)
            } else {
                EmptyHint(
                    icon: "chart.bar",
                    title: "还没有添加账号",
                    message: "添加账号后这里会显示消耗趋势。"
                )
            }
        }
    }

    @ViewBuilder
    private func content(for account: APIAccount) -> some View {
        if account.provider.isPercentBased {
            EmptyHint(
                icon: "chart.bar.xaxis",
                title: "Codex 没有消耗趋势",
                message: "Codex 的接口只给「剩余额度」，\n不提供用量明细，所以画不出消耗曲线。\n\n额度信息请在「总览」里查看。"
            )
            .padding(.top, 20)
        } else {
            deepseekContent(for: account)
        }
    }

    @ViewBuilder
    private func deepseekContent(for account: APIAccount) -> some View {
        let costs = state.dailyCosts(for: account.id, days: range)
        let total = costs.reduce(0) { $0 + $1.cost }
        let activeDays = costs.filter { $0.cost > 0 }
        let average = activeDays.isEmpty ? 0 : total / Double(activeDays.count)

        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $range) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if costs.allSatisfy({ $0.cost == 0 }) {
                EmptyHint(
                    icon: "chart.bar.xaxis",
                    title: "还没有消耗数据",
                    message: "趋势靠本机记录的余额快照推算。\n运行一段时间后这里就会出现曲线。"
                )
            } else {
                Chart(costs) { item in
                    BarMark(
                        x: .value("日期", item.day, unit: .day),
                        y: .value("消耗", item.cost)
                    )
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: range == 7 ? 7 : 6)) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                            .font(.system(size: 9))
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick().foregroundStyle(.clear)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(.system(size: 9))
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.15))
                    }
                }
                .frame(height: 132)

                HStack(spacing: 8) {
                    MetricCard(label: "\(range) 天合计", value: "¥" + formatMoney(total))
                    MetricCard(label: "日均消耗", value: "¥" + formatMoney(average))
                }

                if let daysLeft = state.estimatedDaysRemaining(for: account.id), daysLeft < 999 {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("按近 14 天日均消耗，余额大约还能用 \(String(format: "%.0f", daysLeft)) 天")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("数据来源：本机记录的余额快照差值推算，不是官方账单")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
