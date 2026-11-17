/**
 * Sends one queued Signature Request to its provider. Runs in the background so the call to the
 * provider happens in its own step, after the document and request have been saved.
 */
public with sharing class DocBuilderSignJob implements Queueable, Database.AllowsCallouts {
    Id requestId;

    public DocBuilderSignJob(Id requestId) {
        this.requestId = requestId;
    }

    public void execute(QueueableContext context) {
        DocSignRequest__c request = DocBuilderStore.loadForSending(requestId);
        DocSignRequest__c result = new DocSignRequest__c(Id = requestId);
        Boolean sent = false;
        try {
            DocBuilderSign.Envelope envelope = new DocBuilderSign.Envelope();
            envelope.config = DocBuilderSign.configFor(request.Provider__c);
            envelope.fileName = request.File_Name__c;
            envelope.file = DocBuilderStore.fileData(new Set<Id>{ request.Unsigned_Content_Version_Id__c }).get(request.Unsigned_Content_Version_Id__c).VersionData;
            envelope.subject = request.Subject__c;
            envelope.message = request.Message__c;
            envelope.signers = new List<DocBuilderSign.Signer>();
            for (DocSigner__c row : request.Signers__r) {
                DocBuilderSign.Signer signer = new DocBuilderSign.Signer();
                signer.name = row.Signer_Name__c;
                signer.email = row.Email__c;
                signer.role = row.Role__c;
                signer.routingOrder = row.Routing_Order__c == null ? null : row.Routing_Order__c.intValue();
                envelope.signers.add(signer);
            }

            DocBuilderSign.SendResult response = DocBuilderSign.providerFor(request.Provider__c).send(envelope);
            result.External_Id__c = response == null ? null : response.externalId;
            result.Status__c = 'Sent';
            result.Sent_On__c = System.now();
            result.Error_Message__c = null;
            result.Error_Detail__c = null;
            sent = true;
        } catch (Exception e) {
            result.Status__c = 'Failed';
            result.Error_Message__c = DocBuilderSignHttp.userMessage(e).left(32000);
            result.Error_Detail__c = DocBuilderSignHttp.detailOf(e).left(32000);
        }
        DocBuilderStore.updateRecord(result);
        if (sent) {
            List<DocSigner__c> signers = new List<DocSigner__c>();
            for (DocSigner__c row : request.Signers__r) {
                signers.add(new DocSigner__c(Id = row.Id, Status__c = 'Sent'));
            }
            DocBuilderStore.updateRecords(signers);
        }
    }
}
