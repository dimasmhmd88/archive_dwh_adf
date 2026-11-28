/* =====================================================================================
   DWH Data Retention and Archiving - reset ONE table so that a test Initial Cut-off can be repeated
   -------------------------------------------------------------------------------------
   Script  : test/91_reset_table_for_retest.sql     Version 0.1 (DRAFT)      15 November 2026
   DEV / TEST DATABASES ONLY. Never run in production: the archive inventory is the audit trail
   of the files in Blob Storage and the only way to find data that is no longer in the DWH.

   Order
     1. Run with @Confirm = 0 (default): lists the files of this table that must be deleted in Blob
        Storage and the rows that will be changed. Nothing is changed.
     2. Put the test data back into the table (backup or re-create the test copy).
     3. Delete the listed files / folders in Blob Storage (Portal or Storage Explorer).
     4. Run with @Confirm = 1:
          - ret.RetentionArchiveDate rows of the table -> ExportStatus REMOVED
            (otherwise the next run fails with ERR-EXP-02, decision D-1)
          - ret.RetentionTableStatus -> InitialCutoffStatus PENDING, flags cleared
     Run logs (RetentionRunLog, RetentionTableLog, RetentionStepLog) are kept as history.
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TableConfigId  INT = NULL;     -- <== set, e.g. 36
DECLARE @Confirm        BIT = 0;        -- 0 = preview only, 1 = reset
DECLARE @Comment        NVARCHAR(400) = N'Reset for re-test';

IF @TableConfigId IS NULL OR NOT EXISTS (SELECT 1 FROM ret.RetentionConfig WHERE TableConfigId = @TableConfigId)
BEGIN
    ;THROW 50951, N'Set @TableConfigId to an existing ret.RetentionConfig row.', 1;
END;

IF EXISTS (SELECT 1 FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId)
   OR EXISTS (SELECT 1 FROM ret.RetentionRunLog WHERE Status = 'RUNNING')
BEGIN
    ;THROW 50952, N'A run is RUNNING or the table is locked. Wait for the run to end or close it with ret.usp_AdminCloseStaleRun.', 1;
END;

-- Preview: files to delete in Blob Storage (container from ret.RetentionParameter)
SELECT p.ArchiveContainer, a.RunId, a.BusinessDate, a.ExportStatus,
       a.FolderPath, a.FileName, p.ArchiveContainer + N'/' + a.FolderPath + N'/' + a.FileName AS BlobFile
FROM ret.RetentionArchiveDate AS a
CROSS JOIN ret.RetentionParameter AS p
WHERE p.ParameterSetId = 1 AND a.TableConfigId = @TableConfigId AND a.ExportStatus <> 'REMOVED'
ORDER BY a.BusinessDate, a.RunId;

SELECT c.TableConfigId, c.SchemaName, c.TableName, c.BlobPath, s.InitialCutoffStatus, s.InitialCutoffCompletionDate,
       s.HasOrphanFiles, s.HasIntegrityIssue, s.HasReconciliationWarning
FROM ret.RetentionConfig AS c JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
WHERE c.TableConfigId = @TableConfigId;

IF @Confirm = 1
BEGIN
    BEGIN TRANSACTION;

    UPDATE ret.RetentionArchiveDate
       SET ExportStatus = 'REMOVED'
     WHERE TableConfigId = @TableConfigId AND ExportStatus <> 'REMOVED';

    UPDATE ret.RetentionTableStatus
       SET InitialCutoffStatus         = 'PENDING',
           InitialCutoffCompletionDate = NULL,
           HasOrphanFiles              = 0, OrphanFilesRunId = NULL,
           HasIntegrityIssue           = 0, IntegrityIssueRunId = NULL,
           HasReconciliationWarning    = 0, ReconciliationWarningRunId = NULL,
           FlagComment                 = LEFT(CONCAT(@Comment, N' (', ORIGINAL_LOGIN(), N', ',
                                                     CONVERT(CHAR(16), ret.fn_NowUtc7(), 120), N')'), 400),
           ModifiedBy                  = ORIGINAL_LOGIN(),
           ModifiedAt                  = ret.fn_NowUtc7()
     WHERE TableConfigId = @TableConfigId;

    COMMIT TRANSACTION;

    SELECT N'Reset done. Check that the test data is back in the table and the files are deleted before the next run.' AS Result;
END
ELSE
    SELECT N'Preview only (@Confirm = 0). Nothing changed.' AS Result;
GO
