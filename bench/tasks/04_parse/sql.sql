-- Split on ',', trim spaces, lower-case; a field that is then a valid
-- identifier ([a-z_][a-z0-9_]*, at most 63 bytes) is kept, anything else
-- becomes '?'; the fields are joined with ','.
CREATE FUNCTION t04_sql(line text) RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT string_agg(CASE WHEN f ~ '^[a-z_][a-z0-9_]*$' AND octet_length(f) <= 63
                           THEN f ELSE '?' END, ',' ORDER BY o)
    FROM unnest(string_to_array(line, ',')) WITH ORDINALITY AS u(raw, o),
         LATERAL (SELECT lower(btrim(raw, ' ')) AS f) AS s
$$;
