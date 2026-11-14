-- PL/pgSQL caches the plan of every embedded statement.
CREATE FUNCTION t07_plpgsql(n int) RETURNS bigint LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    s bigint := 0;
    x int;
BEGIN
    FOR i IN 1..n LOOP
        SELECT v INTO x FROM bench_kv WHERE k = i * 7919 % 100000 + 1;
        s := s + x;
    END LOOP;
    RETURN s;
END
$$;
