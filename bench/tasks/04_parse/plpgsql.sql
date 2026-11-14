CREATE FUNCTION t04_plpgsql(line text) RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    f text;
    fields text[] := '{}';
BEGIN
    FOREACH f IN ARRAY string_to_array(line, ',') LOOP
        f := lower(btrim(f, ' '));
        IF f ~ '^[a-z_][a-z0-9_]*$' AND octet_length(f) <= 63 THEN
            fields := array_append(fields, f);
        ELSE
            fields := array_append(fields, '?');
        END IF;
    END LOOP;
    RETURN array_to_string(fields, ',');
END
$$;
