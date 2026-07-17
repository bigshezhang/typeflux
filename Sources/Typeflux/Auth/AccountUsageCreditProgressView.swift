import SwiftUI

struct AccountUsageCreditProgressView: View {
    let credits: CloudCreditSummary?
    let isFreeAllowance: Bool

    init(credits: CloudCreditSummary?, isFreeAllowance: Bool = false) {
        self.credits = credits
        self.isFreeAllowance = isFreeAllowance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.medium) {
                Label {
                    Text(L(isFreeAllowance ? "auth.account.usageFreeQuota" : "auth.account.usageQuota"))
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                } icon: {
                    Image(systemName: "gauge")
                        .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                }
                .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                Text(remainingText)
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(credits?.unlimited == true ? StudioTheme.success : StudioTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if hasFiniteLimit {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.meter, style: .continuous)
                            .fill(StudioTheme.surfaceMuted)

                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.meter, style: .continuous)
                            .fill(progressColor)
                            .frame(width: max(0, proxy.size.width * clampedProgress))
                    }
                }
                .frame(height: 8)
                .accessibilityLabel(L("auth.account.usageQuota"))
                .accessibilityValue(progressDescription)
            }

            Text(progressDescription)
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudioTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .fill(StudioTheme.surfaceMuted.opacity(StudioTheme.Opacity.textFieldFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                .stroke(
                    StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder),
                    lineWidth: StudioTheme.BorderWidth.thin
                )
        )
    }

    private var hasFiniteLimit: Bool {
        guard let credits else { return false }
        return !credits.unlimited && credits.limit > 0
    }

    private var usagePercentage: Double {
        guard hasFiniteLimit, let credits else { return 0 }
        return Double(credits.used) / Double(credits.limit) * 100
    }

    private var clampedProgress: Double {
        min(max(usagePercentage / 100, 0), 1)
    }

    private var progressColor: Color {
        usagePercentage >= 100 ? StudioTheme.danger : StudioTheme.accent
    }

    private var remainingText: String {
        guard let credits else {
            return L("auth.account.usageQuotaUnavailable")
        }
        if credits.unlimited {
            return L("auth.account.usageQuotaUnlimited")
        }
        return String(
            format: L("auth.account.usageQuotaRemaining"),
            AccountUsageDisplayFormatter.creditAmount(credits.remaining)
        )
    }

    private var progressDescription: String {
        guard let credits else {
            return L("auth.account.usageQuotaUnavailable")
        }
        if credits.unlimited {
            return String(
                format: L("auth.account.usageQuotaUsedUnlimited"),
                AccountUsageDisplayFormatter.creditAmount(credits.used)
            )
        }
        if hasFiniteLimit {
            return String(
                format: L("auth.account.usageQuotaUsedOfLimit"),
                AccountUsageDisplayFormatter.creditAmount(credits.used),
                AccountUsageDisplayFormatter.creditAmount(credits.limit),
                AccountUsageDisplayFormatter.percentage(usagePercentage)
            )
        }
        return L("auth.account.usageQuotaUnavailable")
    }
}
