-- Set-based reference: one INSERT ... SELECT and one UPDATE.
CREATE FUNCTION t09_sql(n int) RETURNS int LANGUAGE sql VOLATILE STRICT AS $$
    INSERT INTO bench_t9 SELECT i, i FROM generate_series(1, n) AS i;
    UPDATE bench_t9 SET v = v + 1 WHERE id <= n;
    SELECT n;
$$;
