/**
 * Handles Signature Notice events raised by the public webhook address. Runs outside the site's guest
 * context: as the user set in the event's PlatformEventSubscriberConfig, otherwise the Automated Process user.
 *
 * A notice is only a hint about which request changed. The status itself is always fetched from the
 * provider through its Named Credential, so a forged notice cannot mark a document as signed.
 */
public with sharing class DocBuilderSignNotices {
    static final Integer PER_JOB = 10;
    static final Integer MAX_JOBS = 5;

    public static void handle(List<DocSignNotice__e> notices) {
        Map<String, String> providerByReference = new Map<String, String>();
        for (DocSignNotice__e notice : notices) {
            if (String.isNotBlank(notice.Provider__c) && String.isNotBlank(notice.External_Id__c)) {
                providerByReference.put(notice.External_Id__c, notice.Provider__c);
            }
        }
        if (providerByReference.isEmpty()) {
            return;
        }

        List<Id> ids = new List<Id>();
        for (DocSignRequest__c request : DocBuilderStore.requestsForNotice(providerByReference.keySet())) {
            // The provider in the notice must match the request, so one provider's address cannot trigger another's.
            if (request.Provider__c == providerByReference.get(request.External_Id__c)) {
                ids.add(request.Id);
            }
        }

        // Bounded work per batch of notices; anything left over is picked up by the scheduled check.
        Integer jobs = 0;
        for (Integer i = 0; i < ids.size() && jobs < MAX_JOBS; i += PER_JOB) {
            Set<Id> chunk = new Set<Id>();
            for (Integer j = i; j < Math.min(i + PER_JOB, ids.size()); j++) {
                chunk.add(ids[j]);
            }
            System.enqueueJob(new DocBuilderSignSyncJob(chunk));
            jobs++;
        }
    }
}
