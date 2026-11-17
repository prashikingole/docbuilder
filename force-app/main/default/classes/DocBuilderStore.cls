/**
 * Reads and writes DocBuilder's own system-managed records: generated document audit entries,
 * delivery log rows, bulk job progress, and signature requests with their signers.
 *
 * Security note for reviewers: this class runs in system mode on purpose.
 *  - Users are given read-only access to these objects, so they cannot create or alter the audit
 *    trail themselves; DocBuilder writes it on their behalf.
 *  - Every value written here was produced after the user's own access was checked: record data is
 *    always read in user mode (see DocBuilderContext), and user-facing actions on a signature request
 *    first confirm in user mode that the user can see it (see DocBuilderSign.refresh and cancel).
 *  - Background work (status checks, provider notifications) has no interactive user, and must be able
 *    to update requests owned by whoever sent them.
 */
public without sharing class DocBuilderStore {
    public static void insertRecords(List<SObject> records) {
        if (records != null && !records.isEmpty()) {
            Database.insert(records, true, AccessLevel.SYSTEM_MODE);
        }
    }

    public static void updateRecords(List<SObject> records) {
        if (records != null && !records.isEmpty()) {
            Database.update(records, true, AccessLevel.SYSTEM_MODE);
        }
    }

    public static void insertRecord(SObject record) {
        insertRecords(new List<SObject>{ record });
    }

    public static void updateRecord(SObject record) {
        updateRecords(new List<SObject>{ record });
    }

    public static List<DocSignRequest__c> loadRequests(Set<Id> ids) {
        return [
            SELECT
                Id,
                Provider__c,
                External_Id__c,
                Status__c,
                Record_Id__c,
                File_Name__c,
                Unsigned_Content_Version_Id__c,
                Signed_Content_Version_Id__c,
                (SELECT Id, Email__c, Status__c FROM Signers__r)
            FROM DocSignRequest__c
            WHERE Id IN :ids
            WITH SYSTEM_MODE
        ];
    }

    public static DocSignRequest__c loadForSending(Id requestId) {
        return [
            SELECT
                Id,
                Provider__c,
                File_Name__c,
                Subject__c,
                Message__c,
                Unsigned_Content_Version_Id__c,
                (SELECT Id, Signer_Name__c, Email__c, Role__c, Routing_Order__c FROM Signers__r ORDER BY Routing_Order__c)
            FROM DocSignRequest__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
        ];
    }

    /** Open requests that have waited longest for a status check. */
    public static Set<Id> openRequestIds(Integer maxRows) {
        return new Map<Id, DocSignRequest__c>(
                [
                    SELECT Id
                    FROM DocSignRequest__c
                    WHERE Status__c = 'Sent' AND External_Id__c != NULL
                    WITH SYSTEM_MODE
                    ORDER BY Last_Checked_On__c NULLS FIRST
                    LIMIT :maxRows
                ]
            )
            .keySet();
    }

    /** Open requests matching provider references reported by a notification, skipping any checked in the last 30 seconds. */
    public static List<DocSignRequest__c> requestsForNotice(Set<String> externalIds) {
        Datetime recent = System.now().addSeconds(-30);
        return [
            SELECT Id, Provider__c, External_Id__c
            FROM DocSignRequest__c
            WHERE External_Id__c IN :externalIds AND Status__c = 'Sent' AND (Last_Checked_On__c = NULL OR Last_Checked_On__c < :recent)
            WITH SYSTEM_MODE
            LIMIT 200
        ];
    }

    public static Map<Id, ContentVersion> fileData(Set<Id> contentVersionIds) {
        return new Map<Id, ContentVersion>([SELECT Id, VersionData FROM ContentVersion WHERE Id IN :contentVersionIds WITH SYSTEM_MODE]);
    }

    public static DocGenJob__c lockJob(Id jobId) {
        return [SELECT Id, Succeeded__c, Failed__c FROM DocGenJob__c WHERE Id = :jobId WITH SYSTEM_MODE FOR UPDATE];
    }
}
