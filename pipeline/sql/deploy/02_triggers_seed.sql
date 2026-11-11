/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 02_triggers_seed.sql
   Part of DWH_Retention_DB_Objects_v0.6.sql (DRAFT - not reviewed, not executed against any database).
   Triggers and seed data: parameter row and error codes (sections 2-3)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* =====================================================================================
   2. TRIGGERS
   ===================================================================================== */

-- 2a. New configuration row => status row PENDING (FR-001)
CREATE OR ALTER TRIGGER ret.trg_RetentionConfig_AfterInsert
ON ret.RetentionConfig
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO ret.RetentionTableStatus (TableConfigId)
    SELECT i.TableConfigId
    FROM inserted AS i
    WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus AS s WHERE s.TableConfigId = i.TableConfigId);
END;
GO

-- 2b. Audit columns and protection of identifying attributes once archiving has started (PRC-06)
CREATE OR ALTER TRIGGER ret.trg_RetentionConfig_AfterUpdate
ON ret.RetentionConfig
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRIGGER_NESTLEVEL(@@PROCID) > 1
        RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN deleted  AS d ON d.TableConfigId = i.TableConfigId
        JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = i.TableConfigId
        WHERE (   i.SchemaName <> d.SchemaName
               OR i.TableName  <> d.TableName
               OR ISNULL(i.RetentionColumn, N'') <> ISNULL(d.RetentionColumn, N'')
               OR ISNULL(i.ParentTableConfigId, -1) <> ISNULL(d.ParentTableConfigId, -1)
               OR i.BlobPath COLLATE Latin1_General_100_BIN2 <> d.BlobPath COLLATE Latin1_General_100_BIN2)
          AND (   s.InitialCutoffStatus IN ('RUNNING', 'COMPLETED')
               OR EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l
                          WHERE l.TableConfigId = i.TableConfigId AND l.IsValidated = 1))
    )
    BEGIN
        ;THROW 50001, N'Schema, table, retention column, ParentTableConfigId and blob path cannot be changed after archiving has started for this table (FSD PRC-06 / OQ-22).', 1;
    END;

    UPDATE c
       SET ModifiedBy = ORIGINAL_LOGIN(),
           ModifiedAt = DATEADD(HOUR, 7, SYSUTCDATETIME())
      FROM ret.RetentionConfig AS c
      JOIN inserted AS i ON i.TableConfigId = c.TableConfigId;
END;
GO

-- 2c. Join keys of a child table cannot change once archiving has started (FR-023)
CREATE OR ALTER TRIGGER ret.trg_RetentionParentKey_Protect
ON ret.RetentionParentKey
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM (SELECT TableConfigId FROM inserted UNION SELECT TableConfigId FROM deleted) AS k
        JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = k.TableConfigId
        WHERE s.InitialCutoffStatus IN ('RUNNING', 'COMPLETED')
           OR EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l WHERE l.TableConfigId = k.TableConfigId AND l.IsValidated = 1)
    )
    BEGIN
        ;THROW 50002, N'Join keys of a child table cannot be changed after archiving has started for the table (FSD FR-023 / OQ-22).', 1;
    END;
END;
GO

/* =====================================================================================
   3. SEED DATA
   ===================================================================================== */
IF NOT EXISTS (SELECT 1 FROM ret.RetentionParameter WHERE ParameterSetId = 1)
    INSERT INTO ret.RetentionParameter (ParameterSetId) VALUES (1);
GO

MERGE ret.RetentionErrorCode AS t
USING (VALUES
    ('ERR-CFG-01', N'Configuration / metadata', N'V-01: configured schema or table does not exist in the current database', 0),
    ('ERR-CFG-02', N'Configuration / metadata', N'V-02: retention column does not exist', 0),
    ('ERR-CFG-03', N'Configuration / metadata', N'V-03: retention column is not date, datetime, datetime2 or smalldatetime', 0),
    ('ERR-CFG-04', N'Configuration / metadata', N'V-04: retention column contains NULL values', 0),
    ('ERR-CFG-05', N'Configuration / metadata', N'V-05: invalid retention periods (DWH, archive or log retention years < 1)', 0),
    ('ERR-CFG-06', N'Configuration / metadata', N'V-06: blob path or archive container missing or invalid', 0),
    ('ERR-CFG-07', N'Configuration / metadata', N'V-07: table not eligible for this run (inactive, completed, gates DBR-05, DBR-18, DBR-19)', 0),
    ('ERR-CFG-08', N'Configuration / metadata', N'V-08: column type or column name not supported by the Parquet format', 0),
    ('ERR-CFG-09', N'Configuration / metadata', N'V-09: orphan-file or integrity flag outstanding', 0),
    ('ERR-CFG-11', N'Configuration / child table', N'V-10: header table configuration invalid', 0),
    ('ERR-CFG-12', N'Configuration / child table', N'V-11: join key not unique in the header table', 0),
    ('ERR-PAR-01', N'Child table',              N'Orphan child rows found (no header row); rows kept (DBR-21)', 1),
    ('ERR-LCK-01', N'Concurrency',              N'Table or its header table locked by another run', 0),
    ('ERR-SYS-01', N'Database / connectivity',  N'Query, procedure or connection failure', 0),
    ('ERR-SYS-02', N'Run date',                 N'Run date later than the current UTC+7 date', 0),
    ('ERR-EXP-01', N'Export',                   N'Copy activity failed after retries', 0),
    ('ERR-EXP-02', N'Export',                   N'Archive file for this table and business date may already exist from an earlier run (decision D-1): date refused, table FAILED, manual handling', 0),
    ('ERR-EXP-03', N'Export cleanup',           N'Files written by the failed run could not be removed (orphan files)', 0),
    ('ERR-VAL-01', N'Validation',               N'Per-date or total row-count mismatch between DWH and Parquet', 0),
    ('ERR-VAL-02', N'Validation',               N'Recount differs from the validated total', 0),
    ('ERR-VAL-03', N'Integrity',                N'Resume: remaining rows in validated range exceed the expected count', 0),
    ('ERR-DEL-01', N'Deletion',                 N'Batch delete failed after retries', 0),
    ('ERR-DEL-02', N'Post-check',               N'Rows older than the DWH cut-off remain, or retained rows were lost', 0),
    ('ERR-DEL-03', N'Reconciliation',           N'Deleted total differs from validated total', 1),
    ('ERR-RBD-01', N'Table rebuild',            N'Failure before truncation (RB-01..RB-05); new table dropped, original unchanged', 0),
    ('ERR-RBD-02', N'Table rebuild',            N'Failure inside the truncate, drop and rename transaction (RB-08); rolled back', 0),
    ('ERR-RBD-03', N'Table rebuild',            N'Failure after commit (RB-09, RB-10); DBA procedure required', 0),
    ('ERR-RBD-04', N'Table rebuild',            N'Table not supported for rebuild (RB-01)', 0),
    ('ERR-ARC-01', N'Expired archive deletion', N'Listing or deletion of expired archive folders failed', 0),
    ('ERR-WIN-01', N'Window',                   N'Initial Cut-off Run window end reached; processing stopped', 0)
) AS s (ErrorCode, Category, Description, IsWarning)
ON t.ErrorCode = s.ErrorCode
WHEN MATCHED AND (t.Category <> s.Category OR t.Description <> s.Description OR t.IsWarning <> s.IsWarning)
    THEN UPDATE SET Category = s.Category, Description = s.Description, IsWarning = s.IsWarning
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ErrorCode, Category, Description, IsWarning) VALUES (s.ErrorCode, s.Category, s.Description, s.IsWarning);
GO

-- ERR-CFG-10 (v0.3, database mismatch) is obsolete without the DatabaseName column
DELETE e FROM ret.RetentionErrorCode AS e
WHERE e.ErrorCode = 'ERR-CFG-10'
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE ErrorCode = e.ErrorCode)
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionStepLog  WHERE ErrorCode = e.ErrorCode)
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionRunLog   WHERE ErrorCode = e.ErrorCode);
GO
