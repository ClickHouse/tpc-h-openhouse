SELECT
    `table`,
    formatReadableQuantity(sum(rows)) AS rows,
    formatReadableQuantity(count()) AS parts,
    formatReadableSize(sum(data_uncompressed_bytes)) AS data_size_uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS data_size_compressed,
    formatReadableSize(sum(bytes_on_disk)) AS total_size_on_disk
FROM system.parts
WHERE active AND (database = 'sf100')
GROUP BY `table`
ORDER BY `table` ASC




SELECT
    formatReadableQuantity(sum(rows)) AS rows,
    formatReadableSize(sum(data_compressed_bytes)) AS data_size_compressed,
    formatReadableSize(sum(bytes_on_disk)) AS total_size_on_disk
FROM system.parts
WHERE active AND (database = 'sf100')



SELECT
    formatReadableQuantity(sum(rows)) AS rows,
    formatReadableSize(sum(data_compressed_bytes)) AS data_size_compressed,
    formatReadableSize(sum(bytes_on_disk)) AS total_size_on_disk
FROM system.parts
WHERE active AND (database = 'sf10')



