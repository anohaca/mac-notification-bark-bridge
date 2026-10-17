import Foundation

struct NotificationTimeParser: Sendable {
    var calendar = Calendar.current

    func date(from text: String, now: Date) -> Date? {
        let absoluteText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.fingerprint
        if ["now", "just now", "刚刚", "现在"].contains(text) { return now }
        if ["yesterday", "昨天", "昨日"].contains(text) {
            return calendar.date(byAdding: .day, value: -1, to: now)
        }
        if let parts = captures(#"^(\d+)\s*(秒钟?|分钟?|小时|时|天)\s*前$"#, text)
            ?? captures(#"^(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)\s*(?:ago)?$"#, text),
           let count = Double(parts[0]) {
            let unit = parts[1]
            let factor: Double
            switch unit {
            case "秒", "秒钟", "s", "sec", "secs", "second", "seconds": factor = 1
            case "分", "分钟", "m", "min", "mins", "minute", "minutes": factor = 60
            case "小时", "时", "h", "hr", "hrs", "hour", "hours": factor = 3600
            default: factor = 86400
            }
            let age = count * factor
            guard age.isFinite else { return nil }
            return now.addingTimeInterval(-age)
        }

        if let parts = captures(
            #"^(?:(昨天|yesterday|今天|today)[,， ]*)?(上午|下午|am|pm)?\s*(\d{1,2}):(\d{2})(?:\s*(am|pm))?$"#, text
        ), var hour = Int(parts[2]), let minute = Int(parts[3]), minute < 60 {
            let meridiem = parts[1].isEmpty ? parts[4] : parts[1]
            if !meridiem.isEmpty {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (["pm", "下午"].contains(meridiem) ? 12 : 0)
            }
            guard hour < 24,
                  let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            if ["昨天", "yesterday"].contains(parts[0]) || (parts[0].isEmpty && today > now) {
                return calendar.date(byAdding: .day, value: -1, to: today)
            }
            return today
        }

        if absoluteText.range(of: #"^\d{4}-\d{2}-\d{2}[Tt]"#, options: .regularExpression) != nil {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: absoluteText) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: absoluteText) { return date }
        }
        // These labels carry both a date and a time; avoid guessing a date for arbitrary text.
        if text.range(of: #"^\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日? \d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.isLenient = false
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/M/d HH:mm:ss", "yyyy/M/d HH:mm", "yyyy年M月d日 HH:mm:ss", "yyyy年M月d日 HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    private func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

struct NotificationAgePolicy: Sendable {
    let maxAge: TimeInterval

    func rejectionReason(timestamp: Date?, now: Date) -> String? {
        if maxAge == 0 { return nil }
        guard let timestamp else { return nil }
        let age = now.timeIntervalSince(timestamp)
        guard age.isFinite else { return "time_invalid" }
        if age < 0 { return "time_in_future" }
        return age > maxAge ? "expired" : nil
    }
}
