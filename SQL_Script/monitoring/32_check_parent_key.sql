/* =====================================================================================
   DWH Data Retention and Archiving - check of ret.RetentionParentKey (join keys child -> header)
   -------------------------------------------------------------------------------------
   Script  : SQL_Script/monitoring/32_check_parent_key.sql   Version 0.1 (DRAFT, not executed)   24 November 2026
   Read-only (no data or configuration is changed). Requires SQL v0.6.

   ret.RetentionParentKey holds, per child table (RetentionConfig.ParentTableConfigId filled), the columns that join
   a child row to its header row: ChildColumn (child table) = ParentColumn (header table), KeyOrdinal 1..n.
   The pipeline takes the business date of a child row from the header row found with these keys (FR-023).

   Every result has a column Check: OK / ERROR / WARNING / INFO. Expected: no ERROR rows.

   BLOCKS
     0  Filter
     1  Key rows that do not belong to a child table (ERROR)
     2  Child tables without key rows (ERROR, V-10)
     3  Key numbering and duplicates (KeyOrdinal 1..n without gaps, column used once)
     4  Key columns: exist, compatible type, same collation, nullable (V-10)
     5  Keys compared with the foreign keys in the database (same columns?)
     6  Uniqueness of the key in the header (unique index, or duplicate count when @CountRows = 1) (V-11)
     7  Match rate: child rows that find their header row (orphans, DBR-21) - when @CountRows = 1
     8  Proposed INSERT statements from foreign keys for child tables without key rows (not executed)
     9  Summary per child table
   ===================================================================================== */
SET NOCOUNT ON;

/* ---- 0. Filter ---- */
DECLARE @TableConfigId INT = NULL;   -- NULL = all child tables; a child or a header TableConfigId
DECLARE @CountRows     BIT = NULL;   -- blocks 6/7 read the tables; NULL = only when @TableConfigId is set
SET @CountRows = ISNULL(@CountRows, CASE WHEN @TableConfigId IS NULL THEN 0 ELSE 1 END);

-- child tables in scope with object ids
DECLARE @Child TABLE (ChildId INT PRIMARY KEY, ChildTable NVARCHAR(300), ChildObj INT, HeaderId INT, HeaderTable NVARCHAR(300), HeaderObj INT);
INSERT INTO @Child
SELECT ch.TableConfigId, QUOTENAME(ch.SchemaName) + N'.' + QUOTENAME(ch.TableName),
       OBJECT_ID(QUOTENAME(ch.SchemaName) + N'.' + QUOTENAME(ch.TableName), N'U'),
       h.TableConfigId, QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName),
       OBJECT_ID(QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName), N'U')
FROM ret.RetentionConfig AS ch
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId
WHERE ch.ParentTableConfigId IS NOT NULL
  AND (@TableConfigId IS NULL OR ch.TableConfigId = @TableConfigId OR ch.ParentTableConfigId = @TableConfigId);

SELECT COUNT(*) AS ChildTablesInScope, @TableConfigId AS TableConfigId, @CountRows AS CountRows FROM @Child;

/* ---- 1. Key rows that do not belong to a child table ---- */
SELECT k.TableConfigId, c.SchemaName + N'.' + c.TableName AS ConfiguredTable, k.KeyOrdinal, k.ChildColumn, k.ParentColumn,
       'ERROR - table is not a child table (ParentTableConfigId NULL): keys are ignored; remove them or set ParentTableConfigId' AS [Check]
FROM ret.RetentionParentKey AS k
JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId
WHERE c.ParentTableConfigId IS NULL
  AND (@TableConfigId IS NULL OR k.TableConfigId = @TableConfigId)
ORDER BY k.TableConfigId, k.KeyOrdinal;

/* ---- 2. Child tables without key rows ---- */
SELECT x.ChildId, x.ChildTable, x.HeaderTable,
       'ERROR - no rows in ret.RetentionParentKey (V-10, ERR-CFG-11); see block 8 for a proposal' AS [Check]
FROM @Child AS x
WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId);

/* ---- 3. Key numbering and duplicates ---- */
SELECT x.ChildId, x.ChildTable, COUNT(*) AS KeyRows, MIN(k.KeyOrdinal) AS FirstOrdinal, MAX(k.KeyOrdinal) AS LastOrdinal,
       COUNT(DISTINCT k.ParentColumn) AS DistinctHeaderColumns,
       CASE WHEN MIN(k.KeyOrdinal) <> 1 OR MAX(k.KeyOrdinal) <> COUNT(*) THEN 'WARNING - KeyOrdinal not 1..n without gaps'
            WHEN COUNT(DISTINCT k.ParentColumn) <> COUNT(*) THEN 'ERROR - the same header column is used twice'
            ELSE 'OK' END AS [Check]
FROM @Child AS x
JOIN ret.RetentionParentKey AS k ON k.TableConfigId = x.ChildId
GROUP BY x.ChildId, x.ChildTable
ORDER BY x.ChildId;

/* ---- 4. Key columns ---- */
SELECT x.ChildId, x.ChildTable, x.HeaderTable, k.KeyOrdinal,
       k.ChildColumn,  TYPE_NAME(cc.system_type_id) AS ChildType,  cc.max_length AS ChildLen,  cc.precision AS ChildPrec,  cc.scale AS ChildScale,  cc.is_nullable AS ChildNullable,
       k.ParentColumn, TYPE_NAME(pc.system_type_id) AS HeaderType, pc.max_length AS HeaderLen, pc.precision AS HeaderPrec, pc.scale AS HeaderScale, pc.is_nullable AS HeaderNullable,
       CASE WHEN x.ChildObj IS NULL THEN 'ERROR - child table does not exist'
            WHEN x.HeaderObj IS NULL THEN 'ERROR - header table does not exist'
            WHEN cc.column_id IS NULL THEN 'ERROR - child column not found'
            WHEN pc.column_id IS NULL THEN 'ERROR - header column not found'
            WHEN f.ChildFamily <> f.HeaderFamily THEN 'ERROR - incompatible types (V-10)'
            WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'')
                 THEN 'ERROR - different collations (V-10)'
            WHEN TYPE_NAME(cc.system_type_id) <> TYPE_NAME(pc.system_type_id) OR cc.max_length <> pc.max_length
                 OR cc.precision <> pc.precision OR cc.scale <> pc.scale
                 THEN 'WARNING - same type family but different type/length (implicit conversion, slower join)'
            WHEN cc.is_nullable = 1 THEN 'INFO - child key nullable: rows with NULL key become orphans (kept, DBR-21)'
            ELSE 'OK' END AS [Check]
FROM @Child AS x
JOIN ret.RetentionParentKey AS k ON k.TableConfigId = x.ChildId
LEFT JOIN sys.columns AS cc ON cc.object_id = x.ChildObj  AND cc.name COLLATE DATABASE_DEFAULT = k.ChildColumn
LEFT JOIN sys.columns AS pc ON pc.object_id = x.HeaderObj AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn
CROSS APPLY (SELECT
    CASE WHEN TYPE_NAME(cc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
         WHEN TYPE_NAME(cc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
         WHEN TYPE_NAME(cc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
         ELSE TYPE_NAME(cc.system_type_id) END AS ChildFamily,
    CASE WHEN TYPE_NAME(pc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
         WHEN TYPE_NAME(pc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
         WHEN TYPE_NAME(pc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
         ELSE TYPE_NAME(pc.system_type_id) END AS HeaderFamily) AS f
ORDER BY x.ChildId, k.KeyOrdinal;

/* ---- 5. Keys compared with the foreign keys child -> header in the database ---- */
;WITH reg AS (
    SELECT k.TableConfigId AS ChildId,
           STRING_AGG(CONVERT(NVARCHAR(MAX), k.ChildColumn + N'=' + k.ParentColumn), N', ') WITHIN GROUP (ORDER BY k.ChildColumn) AS RegisteredKeys
    FROM ret.RetentionParentKey AS k
    GROUP BY k.TableConfigId),
fks AS (
    SELECT x.ChildId, fk.name AS ForeignKey,
           STRING_AGG(CONVERT(NVARCHAR(MAX), COL_NAME(fkc.parent_object_id, fkc.parent_column_id) + N'='
                      + COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id)) COLLATE DATABASE_DEFAULT, N', ')
               WITHIN GROUP (ORDER BY COL_NAME(fkc.parent_object_id, fkc.parent_column_id)) AS FkKeys
    FROM @Child AS x
    JOIN sys.foreign_keys AS fk ON fk.parent_object_id = x.ChildObj AND fk.referenced_object_id = x.HeaderObj
    JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
    GROUP BY x.ChildId, fk.name)
SELECT x.ChildId, x.ChildTable, x.HeaderTable, r.RegisteredKeys, f.ForeignKey, f.FkKeys,
       CASE WHEN f.ForeignKey IS NULL THEN 'INFO - no foreign key child -> header in the database (keys cannot be cross-checked)'
            WHEN r.RegisteredKeys IS NULL THEN 'ERROR - foreign key exists but no keys registered (see block 8)'
            WHEN r.RegisteredKeys = f.FkKeys THEN 'OK - same columns as the foreign key'
            ELSE 'WARNING - registered keys differ from the foreign key' END AS [Check]
FROM @Child AS x
LEFT JOIN reg AS r ON r.ChildId = x.ChildId
LEFT JOIN fks AS f ON f.ChildId = x.ChildId
ORDER BY x.ChildId;

/* ---- 6. Uniqueness of the key in the header (V-11) ---- */
DECLARE @Uniq TABLE (ChildId INT, UniqueIndex SYSNAME NULL, DuplicateKeys BIGINT NULL);
INSERT INTO @Uniq (ChildId, UniqueIndex)
SELECT x.ChildId,
       (SELECT TOP (1) i.name FROM sys.indexes AS i
        WHERE i.object_id = x.HeaderObj AND i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0 AND i.is_hypothetical = 0
          AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                          JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                          WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                            AND NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k
                                            WHERE k.TableConfigId = x.ChildId AND k.ParentColumn = c.name COLLATE DATABASE_DEFAULT)))
FROM @Child AS x
WHERE EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId) AND x.HeaderObj IS NOT NULL;

DECLARE @Id INT, @HdrTab NVARCHAR(300), @ChdTab NVARCHAR(300), @KeyList NVARCHAR(MAX), @On NVARCHAR(MAX),
        @FirstP SYSNAME, @sql NVARCHAR(MAX), @Dup BIGINT, @Total BIGINT, @Matched BIGINT, @NullKey BIGINT;
IF @CountRows = 1
BEGIN
    DECLARE cu CURSOR LOCAL FAST_FORWARD FOR
        SELECT u.ChildId, x.HeaderTable FROM @Uniq AS u JOIN @Child AS x ON x.ChildId = u.ChildId WHERE u.UniqueIndex IS NULL;
    OPEN cu;
    FETCH NEXT FROM cu INTO @Id, @HdrTab;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @KeyList = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(ParentColumn)), N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM ret.RetentionParentKey WHERE TableConfigId = @Id;
        SET @sql = N'SELECT @d = COUNT_BIG(*) FROM (SELECT 1 AS x FROM ' + @HdrTab + N' GROUP BY ' + @KeyList
                 + N' HAVING COUNT_BIG(*) > 1) AS q;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@d BIGINT OUTPUT', @d = @Dup OUTPUT;
            UPDATE @Uniq SET DuplicateKeys = @Dup WHERE ChildId = @Id;
        END TRY
        BEGIN CATCH
            UPDATE @Uniq SET DuplicateKeys = -1 WHERE ChildId = @Id;   -- key columns invalid (see block 4)
        END CATCH;
        FETCH NEXT FROM cu INTO @Id, @HdrTab;
    END;
    CLOSE cu; DEALLOCATE cu;
END;

SELECT x.ChildId, x.ChildTable, x.HeaderTable, u.UniqueIndex, u.DuplicateKeys,
       CASE WHEN u.UniqueIndex IS NOT NULL THEN 'OK - unique index on exactly the key columns'
            WHEN u.DuplicateKeys = -1 THEN 'ERROR - duplicate check failed (invalid key columns, block 4)'
            WHEN u.DuplicateKeys > 0 THEN 'ERROR - key not unique in the header (V-11, ERR-CFG-12)'
            WHEN u.DuplicateKeys = 0 THEN 'OK - no duplicates now (no unique index: may change with new data)'
            ELSE 'INFO - no unique index; duplicates not counted (set @CountRows = 1)' END AS [Check]
FROM @Uniq AS u JOIN @Child AS x ON x.ChildId = u.ChildId
ORDER BY x.ChildId;

/* ---- 7. Match rate: child rows that find their header row ---- */
DECLARE @Match TABLE (ChildId INT, ChildRows BIGINT, MatchedRows BIGINT, OrphanRows BIGINT, NullKeyRows BIGINT, Error NVARCHAR(4000));
IF @CountRows = 1
BEGIN
    DECLARE cm CURSOR LOCAL FAST_FORWARD FOR
        SELECT x.ChildId, x.ChildTable, x.HeaderTable FROM @Child AS x
        WHERE x.ChildObj IS NOT NULL AND x.HeaderObj IS NOT NULL
          AND EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId);
    OPEN cm;
    FETCH NEXT FROM cm INTO @Id, @ChdTab, @HdrTab;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @On = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(ParentColumn) + N' = t.' + QUOTENAME(ChildColumn)), N' AND ')
                     WITHIN GROUP (ORDER BY KeyOrdinal),
               @KeyList = STRING_AGG(CONVERT(NVARCHAR(MAX), N't.' + QUOTENAME(ChildColumn) + N' IS NULL'), N' OR ')
                     WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM ret.RetentionParentKey WHERE TableConfigId = @Id;
        -- header matched through a semi-join, so duplicate header keys do not inflate the count
        SET @sql = N'SELECT @t = COUNT_BIG(*),
                            @m = SUM(CASE WHEN EXISTS (SELECT 1 FROM ' + @HdrTab + N' AS p WHERE ' + @On + N') THEN 1 ELSE 0 END),
                            @n = SUM(CASE WHEN ' + @KeyList + N' THEN 1 ELSE 0 END)
                     FROM ' + @ChdTab + N' AS t;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@t BIGINT OUTPUT, @m BIGINT OUTPUT, @n BIGINT OUTPUT',
                 @t = @Total OUTPUT, @m = @Matched OUTPUT, @n = @NullKey OUTPUT;
            INSERT INTO @Match VALUES (@Id, @Total, ISNULL(@Matched, 0), @Total - ISNULL(@Matched, 0), ISNULL(@NullKey, 0), NULL);
        END TRY
        BEGIN CATCH
            INSERT INTO @Match VALUES (@Id, NULL, NULL, NULL, NULL, ERROR_MESSAGE());
        END CATCH;
        FETCH NEXT FROM cm INTO @Id, @ChdTab, @HdrTab;
    END;
    CLOSE cm; DEALLOCATE cm;
END;

SELECT x.ChildId, x.ChildTable, x.HeaderTable, m.ChildRows, m.MatchedRows, m.OrphanRows, m.NullKeyRows,
       CAST(100.0 * m.MatchedRows / NULLIF(m.ChildRows, 0) AS DECIMAL(6, 2)) AS MatchPct,
       CASE WHEN @CountRows = 0 THEN 'INFO - not counted (set @TableConfigId or @CountRows = 1)'
            WHEN m.Error IS NOT NULL THEN 'ERROR - ' + LEFT(m.Error, 300)
            WHEN m.ChildRows > 0 AND m.MatchedRows = 0 THEN 'ERROR - no child row finds a header row: keys probably wrong'
            WHEN m.OrphanRows > 0 THEN 'WARNING - orphan child rows (kept, never archived or deleted, DBR-21)'
            ELSE 'OK' END AS [Check]
FROM @Child AS x
LEFT JOIN @Match AS m ON m.ChildId = x.ChildId
ORDER BY x.ChildId;

/* ---- 8. Proposal from foreign keys (child tables without key rows) - copy, review, then run manually ---- */
SELECT x.ChildId, x.ChildTable, x.HeaderTable, fk.name AS ForeignKey,
       CONCAT(N'INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn) VALUES (',
              x.ChildId, N', ', fkc.constraint_column_id, N', N''', COL_NAME(fkc.parent_object_id, fkc.parent_column_id),
              N''', N''', COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id), N''');') AS ProposedInsert
FROM @Child AS x
JOIN sys.foreign_keys AS fk ON fk.parent_object_id = x.ChildObj AND fk.referenced_object_id = x.HeaderObj
JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId)
ORDER BY x.ChildId, fk.name, fkc.constraint_column_id;
-- Keys cannot be changed after archiving has started for the child table (trigger trg_RetentionParentKey_Protect).

/* ---- 9. Summary per child table ---- */
SELECT x.ChildId, x.ChildTable, x.HeaderId, x.HeaderTable,
       (SELECT COUNT(*) FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId) AS KeyRows,
       u.UniqueIndex, u.DuplicateKeys, m.ChildRows, m.OrphanRows,
       s.InitialCutoffStatus AS ChildIcStatus, c.IsActive AS ChildActive,
       CASE WHEN x.ChildObj IS NULL OR x.HeaderObj IS NULL THEN 'ERROR - table missing'
            WHEN NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = x.ChildId) THEN 'ERROR - no keys'
            WHEN u.DuplicateKeys > 0 OR u.DuplicateKeys = -1 THEN 'ERROR - key not unique / invalid'
            WHEN m.ChildRows > 0 AND m.MatchedRows = 0 THEN 'ERROR - no match'
            WHEN m.OrphanRows > 0 THEN 'WARNING - orphans'
            WHEN @CountRows = 0 AND u.UniqueIndex IS NULL THEN 'CHECK - run with @CountRows = 1'
            ELSE 'OK (see blocks 3-5 for column details)' END AS Summary
FROM @Child AS x
JOIN ret.RetentionConfig AS c ON c.TableConfigId = x.ChildId
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = x.ChildId
LEFT JOIN @Uniq AS u ON u.ChildId = x.ChildId
LEFT JOIN @Match AS m ON m.ChildId = x.ChildId
ORDER BY x.ChildId;
