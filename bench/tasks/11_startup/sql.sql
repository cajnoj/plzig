-- inlined by the planner: the baseline is the bare expression
CREATE FUNCTION t11_sql(x int) RETURNS int LANGUAGE sql IMMUTABLE STRICT
AS $$ SELECT x + 1 $$;
