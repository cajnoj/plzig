-- Appending to an array and joining once: `s := s || ...` in a loop copies
-- the whole string every time (quadratic), arrays are expanded in place.
CREATE FUNCTION t03_plpgsql(n int) RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    parts text[] := '{}';
BEGIN
    FOR i IN 1..n LOOP
        parts := array_append(parts, 'item' || i || ';');
    END LOOP;
    RETURN array_to_string(parts, '');
END
$$;
