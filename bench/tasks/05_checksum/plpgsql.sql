-- (The argument is an in-memory value: `b || ''::bytea` in the query.  A
-- TOASTed argument would be fetched again by every get_byte() call.)
CREATE FUNCTION t05_plpgsql(b bytea) RETURNS bigint LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    h bigint := 2166136261;
BEGIN
    FOR i IN 0..length(b) - 1 LOOP
        h := ((h # get_byte(b, i)) * 16777619) & 4294967295;
    END LOOP;
    RETURN h;
END
$$;
