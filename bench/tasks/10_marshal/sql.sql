-- Inlined: no conversion at all (lower bound).
CREATE FUNCTION t10_text_sql(t text) RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT t $$;
CREATE FUNCTION t10_bytea_sql(b bytea) RETURNS bytea LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT b $$;
