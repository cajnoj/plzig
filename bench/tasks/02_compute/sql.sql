-- count primes <= n by trial division
CREATE FUNCTION t02_primes_sql(n int) RETURNS int LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT count(*)::int
    FROM generate_series(2, n) AS i
    WHERE NOT EXISTS (SELECT 1 FROM generate_series(2, floor(sqrt(i))::int) AS d
                      WHERE i % d = 0)
$$;
-- (no SQL Mandelbrot: possible with a recursive CTE, but not a fair baseline)
