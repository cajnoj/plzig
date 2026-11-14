-- Reference only: levenshtein() is C code from contrib/fuzzystrmatch.
CREATE FUNCTION t06_sql(target text) RETURNS bigint LANGUAGE sql STABLE STRICT AS $$
    SELECT sum(levenshtein(target, w)) FROM bench_words
$$;
