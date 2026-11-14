CREATE FUNCTION t01_plpython(x int) RETURNS int LANGUAGE plpython3u IMMUTABLE STRICT AS $$
return x + 1
$$;
