//
//  PostTimestamp.swift
//  Xray
//

import Foundation

func compactPostTimestamp(for date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))

    if seconds < 60 {
        return "now"
    }
    if seconds < 3_600 {
        return "\(Int(seconds / 60))m"
    }
    if seconds < 86_400 {
        return "\(Int(seconds / 3_600))h"
    }
    if seconds < 604_800 {
        return "\(Int(seconds / 86_400))d"
    }

    let calendar = Calendar.current
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

