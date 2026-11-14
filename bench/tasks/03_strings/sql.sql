-- 'item1;item2;...itemN;'
CREATE FUNCTION t03_sql(n int) RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT string_agg('item' || i || ';', '' ORDER BY i) FROM generate_series(1, n) AS i
$$;
