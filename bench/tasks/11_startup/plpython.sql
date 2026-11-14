CREATE FUNCTION t11_plpython(x int) RETURNS int LANGUAGE plpython3u IMMUTABLE STRICT AS $$
return x + 1
$$;
