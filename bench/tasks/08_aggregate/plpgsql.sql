-- FOR over a query is an implicit cursor (rows fetched in batches).
CREATE FUNCTION t08_plpgsql() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    s bigint := 0;
    c bigint := 0;
    r record;
BEGIN
    FOR r IN SELECT k, v FROM bench_big LOOP
        IF r.k % 3 = 0 THEN
            s := s + r.v;
        END IF;
        c := c + 1;
    END LOOP;
    RETURN s || '/' || c;
END
$$;
