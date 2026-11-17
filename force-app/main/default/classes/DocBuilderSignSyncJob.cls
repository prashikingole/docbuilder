/**
 * Asks providers for the status of Signature Requests and saves what they say.
 * Runs on the schedule for the oldest-checked open requests, or straight away for specific
 * requests named by a provider notification.
 */
public with sharing class DocBuilderSignSyncJob implements Queueable, Database.AllowsCallouts {
    // Kept small: each open request may need a status call and a file download.
    static final Integer PER_RUN = 10;

    Set<Id> only;

    /** Pass null to check the open requests that have waited longest. */
    public DocBuilderSignSyncJob(Set<Id> requestIds) {
        this.only = requestIds;
    }

    public void execute(QueueableContext context) {
        Set<Id> ids = only == null ? DocBuilderStore.openRequestIds(PER_RUN) : only;
        if (ids.isEmpty()) {
            return;
        }
        // All callouts first, then all saving: Salesforce does not allow a callout after a save in the same step.
        List<DocBuilderSign.Outcome> outcomes = new List<DocBuilderSign.Outcome>();
        for (DocSignRequest__c request : DocBuilderStore.loadRequests(ids)) {
            if (String.isNotBlank(request.External_Id__c)) {
                outcomes.add(DocBuilderSign.collect(request));
            }
        }
        DocBuilderSign.apply(outcomes);
    }
}
