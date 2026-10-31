SELECT round(total_exec_time::numeric/1000, 1) AS total_s, calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 1) AS pct, toplevel AS top,
       regexp_replace(left(query, 110), '\s+', ' ', 'g') AS q
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 18;
