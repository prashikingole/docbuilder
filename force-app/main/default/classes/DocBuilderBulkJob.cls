/**
 * Works through a bulk request a few records at a time, chaining itself until every record is done.
 * Progress is kept on the DocGenJob__c record.
 */
public with sharing class DocBuilderBulkJob implements Queueable {
    @TestVisible
    static Integer chunkSize = 10;

    Id jobId;
    String templateName;
    List<Id> recordIds;
    Integer offset;

    public DocBuilderBulkJob(Id jobId, String templateName, List<Id> recordIds, Integer offset) {
        this.jobId = jobId;
        this.templateName = templateName;
        this.recordIds = recordIds;
        this.offset = offset;
    }

    public void execute(QueueableContext context) {
        Integer succeeded = 0;
        Integer failed = 0;
        Integer stop = Math.min(offset + chunkSize, recordIds.size());
        for (Integer i = offset; i < stop; i++) {
            DocBuilder.Request req = new DocBuilder.Request();
            req.templateName = templateName;
            req.recordId = recordIds[i];
            req.channel = 'Bulk';
            req.jobId = jobId;
            if (DocBuilder.generate(req).success) {
                succeeded++;
            } else {
                failed++;
            }
        }

        DocGenJob__c job = DocBuilderStore.lockJob(jobId);
        job.Succeeded__c = (job.Succeeded__c == null ? 0 : job.Succeeded__c) + succeeded;
        job.Failed__c = (job.Failed__c == null ? 0 : job.Failed__c) + failed;
        Boolean finished = stop >= recordIds.size();
        job.Status__c = finished ? 'Done' : 'Running';
        if (finished) {
            job.Finished_On__c = System.now();
        }
        DocBuilderStore.updateRecord(job);

        // Chained jobs cannot be started from a test. The run size is capped when the job is created
        // (DocBuilderPolicy.checkBulk), so the chain always ends.
        if (!finished && !Test.isRunningTest()) {
            System.enqueueJob(new DocBuilderBulkJob(jobId, templateName, recordIds, stop));
        }
    }
}
