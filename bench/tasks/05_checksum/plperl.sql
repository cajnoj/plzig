-- bytea arrives in its text form ('\x...'); decode_bytea gives the bytes.
-- (pack/unpack are not available in trusted PL/Perl.)
CREATE FUNCTION t05_plperl(b bytea) RETURNS bigint LANGUAGE plperl IMMUTABLE STRICT AS $$
    my $d = decode_bytea($_[0]);
    my $h = 2166136261;
    for my $i (0 .. length($d) - 1) {
        $h = (($h ^ ord(substr($d, $i, 1))) * 16777619) & 0xffffffff;
    }
    return $h;
$$;
