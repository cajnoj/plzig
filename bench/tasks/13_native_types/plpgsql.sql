-- numeric arithmetic in a loop
CREATE FUNCTION t13a_plpgsql(n int) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    s numeric := 0;
BEGIN
    FOR i IN 1..n LOOP
        s := s + i * 1.25;
    END LOOP;
    RETURN s;
END
$$;
-- one field of a jsonb document, per row (->>)
CREATE FUNCTION t13b_plpgsql(doc jsonb) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (doc ->> 'qty')::int;
END
$$;
-- a timestamp column summed over a query (FOR is an implicit cursor)
CREATE FUNCTION t13c_plpgsql() RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
    s bigint := 0;
    r record;
BEGIN
    FOR r IN SELECT ts FROM bench_ts LOOP
        s := s + extract(epoch FROM r.ts)::int8;
    END LOOP;
    RETURN s;
END
$$;
