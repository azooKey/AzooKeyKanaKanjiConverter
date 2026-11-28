import Foundation
import SwiftUtils

enum RelativeDateShortcuts {
    // 暦日の加算は最大10年程度に限定し、桁あふれや意図しない巨大な日付を避ける。
    static let maximumDayOffset = 3660

    static func date(matching ruby: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        if ruby == "ゲツマツ" {
            guard let month = calendar.dateInterval(of: .month, for: today) else {
                return nil
            }
            return calendar.date(byAdding: .day, value: -1, to: month.end)
        }
        let prefix = "ライシュウノ"
        if ruby.hasPrefix(prefix) {
            let weekdayReading = String(ruby.dropFirst(prefix.count))
            let weekdays = ["ゲツヨウ", "カヨウ", "スイヨウ", "モクヨウ", "キンヨウ", "ドヨウ", "ニチヨウ"]
            guard let weekday = weekdays.firstIndex(where: { weekdayReading == $0 || weekdayReading == $0 + "ビ" }) else {
                return nil
            }
            // Calendar.firstWeekday（地域設定）によらず、月曜を週の始まりとする。
            let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
            return calendar.date(byAdding: .day, value: 7 - daysSinceMonday + weekday, to: today)
        }
        guard let days = dayOffset(matching: ruby) else {
            return nil
        }
        return calendar.date(byAdding: .day, value: days, to: today)
    }

    private static func dayOffset(matching ruby: String) -> Int? {
        let suffix: String
        let direction: Int
        if ruby.hasSuffix("マエ") {
            suffix = "マエ"
            direction = -1
        } else if ruby.hasSuffix("ゴ") {
            suffix = "ゴ"
            direction = 1
        } else {
            return nil
        }
        let reading = String(ruby.dropLast(suffix.count))
        let naturalReadings = ["イチニチ", "フツカ", "ミッカ", "ヨッカ", "イツカ", "ムイカ", "ナノカ", "ヨウカ", "ココノカ", "トオカ"]
        if let index = naturalReadings.firstIndex(of: reading) {
            return direction * (index + 1)
        }
        guard reading.hasSuffix("ニチ") else {
            return nil
        }
        let digits = reading.dropLast(2).unicodeScalars
        guard !digits.isEmpty, digits.count <= 4 else {
            return nil
        }
        var days = 0
        for scalar in digits {
            let value: UInt32
            switch scalar.value {
            case 0x30...0x39: value = scalar.value - 0x30
            case 0xFF10...0xFF19: value = scalar.value - 0xFF10
            default: return nil
            }
            days = days * 10 + Int(value)
        }
        guard days <= maximumDayOffset else {
            return nil
        }
        return direction * days
    }

    static func candidates(_ inputData: ComposingText, now: Date = Date(), calendar: Calendar = .current) -> [Candidate] {
        guard inputData.convertTargetCursorPosition == inputData.convertTarget.count else {
            return []
        }
        let ruby = inputData.convertTarget.toKatakana()
        guard let date = date(matching: ruby, now: now, calendar: calendar) else {
            return []
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = calendar.timeZone
        return formats.map { format in
            formatter.calendar = Calendar(identifier: format.calendar)
            formatter.dateFormat = format.pattern
            let text = formatter.string(from: date)
            return Candidate(
                text: text, value: format.value,
                composingCount: .inputCount(inputData.input.count), lastMid: MIDData.一般.mid,
                data: [DicdataElement(word: text, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: format.value)],
                isLearningTarget: false
            )
        }
    }

    private struct Format: Sendable {
        let pattern: String
        let value: PValue
        let calendar: Calendar.Identifier
    }

    private static let formats: [Format] = [
        .init(pattern: "M/d", value: -18, calendar: .gregorian),
        .init(pattern: "yyyy/MM/dd", value: -18.1, calendar: .gregorian),
        .init(pattern: "yyyy-MM-dd", value: -18.2, calendar: .gregorian),
        .init(pattern: "M月d日（E）", value: -18.3, calendar: .gregorian),
        .init(pattern: "yyyy年M月d日", value: -18.4, calendar: .gregorian),
        .init(pattern: "Gy年M月d日", value: -18.5, calendar: .japanese),
        .init(pattern: "E曜日", value: -18.6, calendar: .gregorian)
    ]
}
