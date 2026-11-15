--
-- types_calendar: calendar conversions in the SDK (date/time/timestamp <->
-- fields, Julian-day arithmetic ported from PostgreSQL) and time zone
-- conversions by the host (tz_convert), each compared with SQL: make_date,
-- make_time, make_timestamp, EXTRACT, AT TIME ZONE, ::timestamp(tz).
--
\set VERBOSITY terse
SET datestyle = 'ISO, YMD';
SET TimeZone = 'America/New_York';

CREATE FUNCTION cal_err(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Date.fromYmd against make_date: same date, or the matching error
-- (InvalidDate = "date field value out of range", OutOfRange = "date out of range")
CREATE FUNCTION cal_mkdate(y int, m int, d int) RETURNS date STRICT LANGUAGE plzig AS $$
    return try plzig.Date.fromYmd(y, @intCast(m), @intCast(d));
$$;
CREATE FUNCTION cal_class(r text) RETURNS text LANGUAGE sql AS $$
    SELECT CASE WHEN r = 'ok' THEN 'ok'
                WHEN r LIKE '%InvalidDate' OR r LIKE '%InvalidTime' OR r LIKE '%field value out of range%' THEN 'field'
                WHEN r LIKE '%OutOfRange' OR r LIKE '%date out of range%' OR r LIKE '%timestamp out of range%' THEN 'range'
                ELSE r END
$$;
SELECT count(*) AS cases,
       count(*) FILTER (WHERE cal_class(cal_err(format('SELECT cal_mkdate(%s, %s, %s)', y, m, d))) <>
                              cal_class(cal_err(format('SELECT make_date(%s, %s, %s)', y, m, d)))) AS class_mismatches,
       count(*) FILTER (WHERE cal_err(format('SELECT make_date(%s, %s, %s)', y, m, d)) = 'ok'
                          AND cal_mkdate(y, m, d) <> make_date(y, m, d)) AS value_mismatches,
       count(*) FILTER (WHERE cal_err(format('SELECT make_date(%s, %s, %s)', y, m, d)) = 'ok') AS valid
FROM unnest(ARRAY[-4715, -4714, -4713, -401, -400, -101, -100, -5, -4, -2, -1, 0, 1, 2, 4, 100, 400, 1582,
                  1900, 1999, 2000, 2023, 2024, 2100, 9999, 294276, 5874897, 5874898]) y,
     generate_series(0, 13) m, unnest(ARRAY[0, 1, 2, 23, 24, 25, 28, 29, 30, 31, 32]) d;
SELECT cal_mkdate(-4714, 11, 24), cal_mkdate(5874897, 12, 31), cal_mkdate(-1, 2, 29), cal_mkdate(1, 1, 1);
SELECT cal_err('SELECT cal_mkdate(0, 1, 1)'), cal_err('SELECT cal_mkdate(-4714, 11, 23)'), cal_err('SELECT cal_mkdate(2023, 2, 29)');

-- Date fields, day of week and of year against EXTRACT, for many dates
-- across the whole range
CREATE FUNCTION cal_ymd(d date) RETURNS text STRICT LANGUAGE plzig AS $$
    const f = try d.ymd();
    return try std.fmt.allocPrint(plzig.allocator, "{d} {d} {d} {d} {d}", .{ f.year, f.month, f.day, try d.dayOfWeek(), try d.dayOfYear() });
$$;
CREATE TABLE cal_dates AS
SELECT date '4714-11-24 BC' + (g::bigint * 2147483 % 2147483494)::int AS d FROM generate_series(0, 999) g
UNION ALL SELECT unnest(ARRAY['4714-11-24 BC', '0001-12-31 BC', '0001-01-01', '1582-10-04', '1582-10-15', '1900-02-28',
                              '1900-03-01', '2000-02-29', '2000-12-31', '2024-02-29', '2024-12-31', '5874897-12-31']::date[]);
SELECT count(*) AS dates,
       count(*) FILTER (WHERE cal_ymd(d) <> format('%s %s %s %s %s', extract(year FROM d), extract(month FROM d),
                                                    extract(day FROM d), extract(dow FROM d), extract(doy FROM d))) AS mismatches,
       count(*) FILTER (WHERE cal_mkdate(split_part(cal_ymd(d), ' ', 1)::int, split_part(cal_ymd(d), ' ', 2)::int,
                                         split_part(cal_ymd(d), ' ', 3)::int) <> d) AS roundtrip_mismatches
FROM cal_dates;
SELECT cal_err('SELECT cal_ymd(''infinity'')');

-- Time.fromHms / hms against make_time and EXTRACT
CREATE FUNCTION cal_mktime(h int, m int, s int, us int) RETURNS time STRICT LANGUAGE plzig AS $$
    return try plzig.Time.fromHms(@intCast(h), @intCast(m), @intCast(s), @intCast(us));
$$;
CREATE FUNCTION cal_hms(t time) RETURNS text STRICT LANGUAGE plzig AS $$
    const f = t.hms();
    return try std.fmt.allocPrint(plzig.allocator, "{d}:{d}:{d}.{d}", .{ f.hour, f.minute, f.second, f.microsecond });
$$;
SELECT count(*) AS cases,
       count(*) FILTER (WHERE cal_class(cal_err(format('SELECT cal_mktime(%s, %s, %s, %s)', h, m, s, us))) <>
                              cal_class(cal_err(format('SELECT make_time(%s, %s, %s + %s / 1e6)', h, m, s, us)))) AS class_mismatches,
       count(*) FILTER (WHERE cal_err(format('SELECT make_time(%s, %s, %s + %s / 1e6)', h, m, s, us)) = 'ok'
                          AND cal_mktime(h, m, s, us) <> make_time(h, m, s + us / 1e6)) AS value_mismatches
FROM unnest(ARRAY[0, 1, 12, 23, 24, 25]) h, unnest(ARRAY[0, 1, 59, 60]) m, unnest(ARRAY[0, 1, 59, 60, 61]) s,
     unnest(ARRAY[0, 1, 999999]) us;
SELECT count(*) FILTER (WHERE cal_hms(t) <> format('%s:%s:%s.%s', extract(hour FROM t), extract(minute FROM t),
                                                  floor(extract(second FROM t)), extract(microseconds FROM t)::int % 1000000)) AS hms_mismatches
FROM (SELECT time '00:00' + g * interval '1 second 7 microseconds' * 4321 AS t FROM generate_series(0, 2000) g
      UNION ALL SELECT '24:00:00') s;

-- Timestamp.fromFields / fields against make_timestamp and EXTRACT (BC
-- years through make_date + make_time, which every version takes)
CREATE FUNCTION cal_mkts(y int, mo int, d int, h int, mi int, s int, us int) RETURNS timestamp STRICT LANGUAGE plzig AS $$
    return try plzig.Timestamp.fromFields(.{ .year = y, .month = @intCast(mo), .day = @intCast(d),
        .hour = @intCast(h), .minute = @intCast(mi), .second = @intCast(s), .microsecond = @intCast(us) });
$$;
CREATE FUNCTION cal_fields(t timestamp) RETURNS text STRICT LANGUAGE plzig AS $$
    const f = try t.fields();
    return try std.fmt.allocPrint(plzig.allocator, "{d} {d} {d} {d} {d} {d} {d} {d}", .{
        f.year, f.month, f.day, f.hour, f.minute, f.second, f.microsecond, t.date().days });
$$;
SELECT count(*) AS cases,
       count(*) FILTER (WHERE cal_class(cal_err(format('SELECT cal_mkts(%s, %s, %s, %s, %s, %s, %s)', y, mo, d, h, mi, s, us))) <>
                              cal_class(cal_err(format('SELECT make_timestamp(%s, %s, %s, %s, %s, %s + %s / 1e6)', y, mo, d, h, mi, s, us)))) AS class_mismatches,
       count(*) FILTER (WHERE cal_err(format('SELECT make_timestamp(%s, %s, %s, %s, %s, %s + %s / 1e6)', y, mo, d, h, mi, s, us)) = 'ok'
                          AND cal_mkts(y, mo, d, h, mi, s, us) <> make_timestamp(y, mo, d, h, mi, s + us / 1e6)) AS value_mismatches
FROM unnest(ARRAY[-4714, -1, 1, 1999, 2016, 2024, 294276, 294277]) y, unnest(ARRAY[0, 1, 2, 11, 12, 13]) mo,
     unnest(ARRAY[0, 1, 23, 24, 29, 31, 32]) d, unnest(ARRAY[0, 23, 24]) h, unnest(ARRAY[0, 59]) mi,
     unnest(ARRAY[0, 59, 60]) s, unnest(ARRAY[0, 999999]) us;
-- leap second input, as PostgreSQL normalises it
SELECT cal_mkts(2016, 12, 31, 23, 59, 60, 0), timestamp '2016-12-31 23:59:60',
       cal_mkts(2016, 12, 31, 23, 59, 60, 0) = timestamp '2016-12-31 23:59:60' AS same;
CREATE TABLE cal_ts AS
SELECT timestamp '4714-11-24 00:00:00 BC' + (g::numeric * 1234567890123457 % 294276000000000000 / 1e6) * interval '1 second' AS t
  FROM generate_series(0, 999) g
UNION ALL SELECT unnest(ARRAY['4714-11-24 00:00:00 BC', '0001-12-31 23:59:59.999999 BC', '1999-12-31 23:59:59.999999',
                              '2000-01-01', '294276-12-31 23:59:59.999999']::timestamp[]);
SELECT count(*) AS timestamps,
       count(*) FILTER (WHERE cal_fields(t) <> format('%s %s %s %s %s %s %s %s', extract(year FROM t), extract(month FROM t),
                         extract(day FROM t), extract(hour FROM t), extract(minute FROM t), floor(extract(second FROM t)),
                         extract(microseconds FROM t)::int % 1000000, t::date - date '2000-01-01')) AS mismatches
FROM cal_ts;
SELECT cal_err('SELECT cal_fields(''-infinity'')');

-- time zones: by the host, exactly PostgreSQL's conversions
CREATE FUNCTION cal_local(t timestamptz, zone text) RETURNS timestamp STRICT LANGUAGE plzig AS $$
    return t.toLocal(if (zone.len == 0) null else zone);
$$;
CREATE FUNCTION cal_from_local(t timestamp, zone text) RETURNS timestamptz STRICT LANGUAGE plzig AS $$
    return plzig.TimestampTz.fromLocal(t, if (zone.len == 0) null else zone);
$$;
CREATE TABLE cal_moments AS
SELECT timestamptz '1900-01-01 00:00+00' + g * interval '17 hours 3 minutes 7.5 seconds' * 1013 AS t FROM generate_series(0, 1500) g
UNION ALL SELECT unnest(ARRAY['2024-03-10 06:59:59+00', '2024-03-10 07:00:00+00', '2024-11-03 05:59:59+00',
                              '2024-11-03 06:00:00+00', '2024-03-31 00:59:59+00', '2024-03-31 01:00:00+00',
                              'infinity', '-infinity', '4714-11-24 00:00:00+00 BC']::timestamptz[]);
SELECT zone, count(*) AS moments,
       count(*) FILTER (WHERE cal_local(t, zone) IS DISTINCT FROM (t AT TIME ZONE zone)) AS to_local_mismatches,
       count(*) FILTER (WHERE cal_from_local(t::timestamp, zone) IS DISTINCT FROM (t::timestamp AT TIME ZONE zone)) AS from_local_mismatches
FROM cal_moments, unnest(ARRAY['UTC', 'Europe/Berlin', 'America/New_York', 'Asia/Kathmandu', 'Australia/Lord_Howe',
                               'Pacific/Chatham', 'EST', 'UTC+3', '-07:30', 'PST8PDT']) zone
WHERE t > '1000-01-01' OR NOT isfinite(t)
GROUP BY zone ORDER BY zone;
-- the session's TimeZone when no zone is given
SET TimeZone = 'Asia/Tokyo';
SELECT count(*) FILTER (WHERE cal_local(t, '') IS DISTINCT FROM t::timestamp) AS session_to_local_mismatches,
       count(*) FILTER (WHERE cal_from_local(t::timestamp, '') IS DISTINCT FROM t::timestamp::timestamptz) AS session_from_local_mismatches
FROM cal_moments;
SET TimeZone = 'America/New_York';
-- skipped and repeated local times (spring forward, fall back)
SELECT l, cal_from_local(l, 'America/New_York'), l AT TIME ZONE 'America/New_York' AS sql
FROM unnest(ARRAY['2024-03-10 02:30:00', '2024-11-03 01:30:00']::timestamp[]) l;
-- fields in a zone, and a moment from local fields
CREATE FUNCTION cal_tz_fields(t timestamptz, zone text) RETURNS text STRICT LANGUAGE plzig AS $$
    const f = try t.fields(zone);
    const back = try plzig.TimestampTz.fromFields(f, zone);
    return try std.fmt.allocPrint(plzig.allocator, "{d}-{d}-{d} {d}:{d}:{d} {}", .{ f.year, f.month, f.day, f.hour, f.minute, f.second, back.usecs == t.usecs });
$$;
SELECT cal_tz_fields('2024-07-01 12:00:00+00', 'Asia/Kathmandu'), cal_tz_fields('2024-01-01 00:00:00+00', 'America/New_York');
-- errors: an unknown zone, a value out of range, a result out of range
CREATE FUNCTION cal_bad_value() RETURNS timestamp LANGUAGE plzig AS $$
    return (plzig.TimestampTz{ .usecs = 9223371331200000000 }).toLocal("UTC");
$$;
SELECT cal_err('SELECT cal_local(now(), ''Mars/Olympus_Mons'')'), cal_err('SELECT cal_bad_value()'),
       cal_err('SELECT cal_local(''294276-12-31 23:00:00+00'', ''Asia/Tokyo'')') = cal_err('SELECT ''294276-12-31 23:00:00+00''::timestamptz AT TIME ZONE ''Asia/Tokyo''') AS same_error;
SELECT cal_err(format('SELECT cal_local(now(), %L)', repeat('x', 2000)));

DROP TABLE cal_dates, cal_ts, cal_moments;
