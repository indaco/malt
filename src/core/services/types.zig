//! malt — service schedule model
//!
//! A std-only leaf shared by the formula parser and the plist emitter, so
//! neither side has to import the other just to name a schedule.

/// One launchd `StartCalendarInterval` entry. Defined now so adding cron
/// support is purely additive; unused until then.
pub const CalendarInterval = struct {
    minute: ?u8 = null,
    hour: ?u8 = null,
    day: ?u8 = null,
    weekday: ?u8 = null,
    month: ?u8 = null,
};

/// How a service is scheduled under launchd.
pub const Schedule = union(enum) {
    /// `RunAtLoad true`, no interval — run once when loaded (today's default).
    immediate,
    /// `RunAtLoad false` + `StartInterval <secs>`.
    interval: u32,
    /// `StartCalendarInterval` — not emitted yet; reserved for cron support.
    calendar: []const CalendarInterval,
};

/// Upper bound on a `StartInterval`, in seconds. A year is far beyond any
/// real periodic service while keeping the value a small bounded integer —
/// the same value gates both the parser and `plist.validate`.
pub const max_interval_secs: u32 = 365 * 24 * 60 * 60;

/// Cap on enumerated `StartCalendarInterval` entries. A pathological cron
/// expansion (e.g. `*/1` across two fields) would otherwise produce a huge
/// plist; 60 covers every real formula ("every 5 minutes" is 12 entries)
/// while staying small. Gates both the cron parser and `plist.validate`.
pub const max_calendar_entries: usize = 60;
