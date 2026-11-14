CREATE FUNCTION t10_text_plpython(t text) RETURNS text LANGUAGE plpython3u IMMUTABLE STRICT AS $$
return t
$$;
CREATE FUNCTION t10_bytea_plpython(b bytea) RETURNS bytea LANGUAGE plpython3u IMMUTABLE STRICT AS $$
return b
$$;
