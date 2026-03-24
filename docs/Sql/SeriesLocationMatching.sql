-- Check Series matching Location
-- Test inclusion logic by replacing the
-- county code (COC001), fire zone, (COZ245)
-- and the h3 cell is an int64 representation
-- of the cell id


SELECT s.*, g.*
FROM arcus_series s
LEFT JOIN arcus_geolocation g on g.series_id = s.id
WHERE 
  'COC001' = ANY(s.ugc_codes)
  OR 'COZ245' = ANY(s.ugc_codes)
  OR '613164810799939583' = ANY(g.h3_cells)
ORDER BY s.ends DESC

-- 88263681ddfffff - outside -> 613161798104776703
-- 88263681d1fffff - edge.   -> 613161798092193791
-- 88263680ebfffff - inside. -> 613161797851021311

SELECT id, cardinality(h3_cells) AS tag_count FROM arcus_geolocation where id = 'e46b30b5-d3ed-4c05-a43a-f46e7dd6d6c9'

SELECT
    (get_byte(b, 0)::bigint << 56) |
    (get_byte(b, 1)::bigint << 48) |
    (get_byte(b, 2)::bigint << 40) |
    (get_byte(b, 3)::bigint << 32) |
    (get_byte(b, 4)::bigint << 24) |
    (get_byte(b, 5)::bigint << 16) |
    (get_byte(b, 6)::bigint <<  8) |
     get_byte(b, 7)::bigint       AS h3_bigint
FROM (
    SELECT decode(lpad('88263680ebfffff', 16, '0'), 'hex') AS b
) t;