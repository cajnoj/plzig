CREATE FUNCTION t10_text_plzig(t text) RETURNS text LANGUAGE plzig IMMUTABLE STRICT AS $$
    return t;
$$;
CREATE FUNCTION t10_bytea_plzig(b bytea) RETURNS bytea LANGUAGE plzig IMMUTABLE STRICT AS $$
    return b;
$$;
