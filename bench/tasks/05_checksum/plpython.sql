CREATE FUNCTION t05_plpython(b bytea) RETURNS bigint LANGUAGE plpython3u IMMUTABLE STRICT AS $$
h = 2166136261
for c in b:
    h = ((h ^ c) * 16777619) & 0xffffffff
return h
$$;
