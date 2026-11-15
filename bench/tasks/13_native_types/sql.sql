-- task 13 references: one set-based statement each
CREATE FUNCTION t13a_sql(n int) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT sum(i * 1.25) FROM generate_series(1, n) AS i
$$;
CREATE FUNCTION t13b_sql(doc jsonb) RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT (doc ->> 'qty')::int
$$;
CREATE FUNCTION t13c_sql() RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT sum(extract(epoch FROM ts)::int8) FROM bench_ts
$$;
