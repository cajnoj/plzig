CREATE FUNCTION t08_sql() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT (sum(v) FILTER (WHERE k % 3 = 0)) || '/' || count(*) FROM bench_big
$$;
