CREATE FUNCTION t11_plzig(x int) RETURNS int LANGUAGE plzig IMMUTABLE STRICT AS $$
    return x + 1;
$$;
