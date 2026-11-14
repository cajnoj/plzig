-- Set-based reference (one join), not a loop.
CREATE FUNCTION t07_sql(n int) RETURNS bigint LANGUAGE sql STABLE STRICT AS $$
    SELECT sum(v) FROM generate_series(1, n) AS i JOIN bench_kv ON k = i * 7919 % 100000 + 1
$$;
