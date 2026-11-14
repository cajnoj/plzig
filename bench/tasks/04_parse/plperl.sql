CREATE FUNCTION t04_plperl(line text) RETURNS text LANGUAGE plperl IMMUTABLE STRICT AS $$
    my ($line) = @_;
    my @out;
    for my $f (split /,/, $line, -1) {
        $f =~ s/^ +| +$//g;
        $f = lc $f;
        push @out, ($f =~ /\A[a-z_][a-z0-9_]{0,62}\z/ ? $f : '?');
    }
    return join ',', @out;
$$;
