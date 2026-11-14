CREATE FUNCTION t06_plpython(target text) RETURNS bigint LANGUAGE plpython3u STABLE STRICT AS $$
plan = SD.get('plan')
if plan is None:
    plan = SD['plan'] = plpy.prepare("SELECT w FROM bench_words")
total = 0
for row in plpy.execute(plan):
    w = row['w']
    prev = list(range(len(w) + 1))
    for i, ca in enumerate(target, 1):
        cur = [i]
        for j, cb in enumerate(w, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    total += prev[-1]
return total
$$;
