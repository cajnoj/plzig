-- Sum of the Levenshtein distances between target and every word.
CREATE FUNCTION t06_plpgsql(target text) RETURNS bigint LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    a text[] := string_to_array(target, NULL);
    la int := cardinality(a);
    b text[];
    lb int;
    prev int[];
    cur int[];
    cost int;
    total bigint := 0;
    r record;
BEGIN
    FOR r IN SELECT w FROM bench_words LOOP
        b := string_to_array(r.w, NULL);
        lb := cardinality(b);
        prev := '{0}';
        FOR j IN 1..lb LOOP
            prev := prev || j;
        END LOOP;
        FOR i IN 1..la LOOP
            cur := ARRAY[i];
            FOR j IN 1..lb LOOP
                cost := CASE WHEN a[i] = b[j] THEN 0 ELSE 1 END;
                cur := cur || least(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost);
            END LOOP;
            prev := cur;
        END LOOP;
        total := total + prev[lb + 1];
    END LOOP;
    RETURN total;
END
$$;
