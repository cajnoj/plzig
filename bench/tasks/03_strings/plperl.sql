CREATE FUNCTION t03_plperl(n int) RETURNS text LANGUAGE plperl IMMUTABLE STRICT AS $$
    my ($n) = @_;
    my $s = '';
    $s .= "item$_;" for 1 .. $n;
    return $s;
$$;
