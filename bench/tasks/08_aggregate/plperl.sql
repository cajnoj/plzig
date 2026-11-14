CREATE FUNCTION t08_plperl() RETURNS text LANGUAGE plperl STABLE AS $$
    my $plan = $_SHARED{t08_plan} //= spi_prepare('SELECT k, v FROM bench_big');
    my $cursor = spi_query_prepared($plan);
    my ($s, $c) = (0, 0);
    while (defined(my $r = spi_fetchrow($cursor))) {
        $s += $r->{v} if $r->{k} % 3 == 0;
        $c++;
    }
    return "$s/$c";
$$;
