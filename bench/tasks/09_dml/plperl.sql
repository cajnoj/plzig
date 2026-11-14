CREATE FUNCTION t09_plperl(n int) RETURNS int LANGUAGE plperl VOLATILE STRICT AS $$
    my ($n) = @_;
    my $ins = $_SHARED{t09_ins} //= spi_prepare('INSERT INTO bench_t9 VALUES ($1, $2)', 'int4', 'int4');
    my $upd = $_SHARED{t09_upd} //= spi_prepare('UPDATE bench_t9 SET v = v + 1 WHERE id = $1', 'int4');
    spi_exec_prepared($ins, $_, $_) for 1 .. $n;
    spi_exec_prepared($upd, $_) for 1 .. $n;
    return $n;
$$;
