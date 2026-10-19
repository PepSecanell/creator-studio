//! Small calendar helpers. No time crate: the app only needs days, ISO weeks and UTC stamps.

use std::time::{SystemTime, UNIX_EPOCH};

const DAY_SHORT: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const MONTH_SHORT: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Days since 1970-01-01 for a civil date.
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn fmt_date(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

pub fn parse_date(s: &str) -> Option<i64> {
    let p: Vec<&str> = s.trim().split('-').collect();
    if p.len() != 3 {
        return None;
    }
    let (y, m, d) = (p[0].parse::<i64>().ok()?, p[1].parse::<i64>().ok()?, p[2].parse::<i64>().ok()?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

/// 0 = Monday.
pub fn weekday(days: i64) -> usize {
    (days + 3).rem_euclid(7) as usize
}

pub fn nice_date(days: i64) -> String {
    let (_, m, d) = civil_from_days(days);
    format!("{} {} {}", DAY_SHORT[weekday(days)], d, MONTH_SHORT[(m - 1) as usize])
}

pub fn today_utc() -> i64 {
    (now_secs() / 86400) as i64
}

/// Today in the local time zone (`date` knows it; falls back to UTC if the command is missing).
pub fn today_local() -> String {
    std::process::Command::new("date")
        .arg("+%Y-%m-%d")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| parse_date(s).is_some())
        .unwrap_or_else(|| fmt_date(today_utc()))
}

pub fn utc_iso(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    format!("{}T{:02}:{:02}:{:02}Z", fmt_date(days), rem / 3600, (rem % 3600) / 60, rem % 60)
}

pub fn iso_now() -> String {
    utc_iso(now_secs())
}

/// ISO year and week number of a day.
pub fn iso_week(days: i64) -> (i64, i64) {
    let thursday = days - weekday(days) as i64 + 3;
    let (year, _, _) = civil_from_days(thursday);
    let jan1 = days_from_civil(year, 1, 1);
    (year, (thursday - jan1) / 7 + 1)
}

/// The Monday of an ISO week.
pub fn iso_week_start(year: i64, week: i64) -> i64 {
    let jan4 = days_from_civil(year, 1, 4);
    jan4 - weekday(jan4) as i64 + (week - 1) * 7
}

pub fn week_label(year: i64, week: i64) -> String {
    format!("{year}-W{week:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_round_trip() {
        let d = parse_date("2026-10-19").unwrap();
        assert_eq!(fmt_date(d), "2026-10-19");
        assert_eq!(weekday(d), 0);
    }

    #[test]
    fn iso_weeks_match_the_calendar() {
        assert_eq!(iso_week(parse_date("2026-10-19").unwrap()), (2026, 43));
        assert_eq!(iso_week(parse_date("2026-01-01").unwrap()), (2026, 1));
        assert_eq!(fmt_date(iso_week_start(2026, 43)), "2026-10-19");
        assert_eq!(iso_week(parse_date("2027-01-01").unwrap()), (2026, 53));
    }

    #[test]
    fn utc_stamp() {
        assert_eq!(utc_iso(0), "1970-01-01T00:00:00Z");
    }
}
