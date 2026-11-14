CREATE FUNCTION t11_plperl(x int) RETURNS int LANGUAGE plperl IMMUTABLE STRICT AS $$
    return $_[0] + 1;
$$;
