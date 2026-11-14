CREATE FUNCTION t06_plperl(target text) RETURNS bigint LANGUAGE plperl STABLE STRICT AS $$
    my @a = split //, $_[0];
    my $plan = $_SHARED{t06_plan} //= spi_prepare('SELECT w FROM bench_words');
    my $cursor = spi_query_prepared($plan);
    my $total = 0;
    while (defined(my $row = spi_fetchrow($cursor))) {
        my @b = split //, $row->{w};
        my @prev = (0 .. scalar @b);
        for my $i (1 .. @a) {
            my @cur = ($i);
            for my $j (1 .. @b) {
                my $cost = $a[$i - 1] eq $b[$j - 1] ? 0 : 1;
                my $m = $prev[$j] + 1;
                $m = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $m;
                $m = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $m;
                push @cur, $m;
            }
            @prev = @cur;
        }
        $total += $prev[-1];
    }
    return $total;
$$;
