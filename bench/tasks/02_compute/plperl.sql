CREATE FUNCTION t02_primes_plperl(n int) RETURNS int LANGUAGE plperl IMMUTABLE STRICT AS $$
    my ($n) = @_;
    my $c = 0;
    I: for my $i (2 .. $n) {
        for (my $d = 2; $d * $d <= $i; $d++) {
            next I if $i % $d == 0;
        }
        $c++;
    }
    return $c;
$$;

CREATE FUNCTION t02_mandel_plperl(w int, maxiter int) RETURNS bigint LANGUAGE plperl IMMUTABLE STRICT AS $$
    my ($w, $maxiter) = @_;
    my $total = 0;
    my $ci = 0.35;
    for my $i (0 .. $w - 1) {
        my $cr = -2.0 + (2.5 * $i) / $w;
        my ($zr, $zi, $k) = (0.0, 0.0, 0);
        while ($k < $maxiter && $zr * $zr + $zi * $zi <= 4.0) {
            ($zr, $zi) = ($zr * $zr - $zi * $zi + $cr, 2.0 * $zr * $zi + $ci);
            $k++;
        }
        $total += $k;
    }
    return $total;
$$;
