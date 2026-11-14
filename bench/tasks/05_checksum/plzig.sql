CREATE FUNCTION t05_plzig(b bytea) RETURNS bigint LANGUAGE plzig IMMUTABLE STRICT AS $$
    var h: u32 = 2166136261;
    for (b) |c| h = (h ^ c) *% 16777619;
    return h;
$$;
