-- bytea crosses as its text form ('\x...' hex) both ways: PL/Perl's default.
CREATE FUNCTION t10_text_plperl(t text) RETURNS text LANGUAGE plperl IMMUTABLE STRICT AS $$
    return $_[0];
$$;
CREATE FUNCTION t10_bytea_plperl(b bytea) RETURNS bytea LANGUAGE plperl IMMUTABLE STRICT AS $$
    return $_[0];
$$;
