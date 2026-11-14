CREATE FUNCTION t03_plpython(n int) RETURNS text LANGUAGE plpython3u IMMUTABLE STRICT AS $$
return ''.join([f'item{i};' for i in range(1, n + 1)])
$$;
