CREATE FUNCTION t07_plperl(n int) RETURNS bigint LANGUAGE plperl STABLE STRICT AS $$
    my ($n) = @_;
    my $plan = $_SHARED{t07_plan} //= spi_prepare('SELECT v FROM bench_kv WHERE k = $1', 'int4');
    my $s = 0;
    for my $i (1 .. $n) {
        $s += spi_exec_prepared($plan, $i * 7919 % 100000 + 1)->{rows}[0]{v};
    }
    return $s;
$$;
