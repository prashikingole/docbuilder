/**
 * Public entry point for generating documents from DocBuilder templates.
 * The record button, the Flow action and custom Apex all go through generate().
 */
global with sharing class DocBuilder {
    global class DocBuilderException extends Exception {
    }

    global class Request {
        /** Name of an active template. Used when templateId is not set. */
        global String templateName;
        global Id templateId;
        /** Optional. More templates to append to the same document, each starting on a new page. */
        global List<Id> additionalTemplateIds;
        /** Record the document is generated from. Must match the template's base object. */
        global Id recordId;
        /** Optional language code, e.g. fr. Text without a translation prints in the default language. */
        global String language;
        /** When true the document carries a DRAFT watermark and file name suffix. */
        global Boolean draft = false;
        /** When true (default) the file is attached to the source record. */
        global Boolean saveToRecord = true;
        /** Optional. When set, the generated file is emailed as an attachment. */
        global List<String> emailTo;
        global String emailSubject;
        global String emailBody;
        /** Where the request came from: Apex, Button, Flow or Bulk. */
        global String channel = 'Apex';
        /** Set by bulk jobs so each document links back to its job. */
        global Id jobId;
        /** Optional. Signers to print in place of the ones worked out from the template; keep the same order. */
        global List<DocBuilderSign.Signer> signers;
        /** Set when the document is going out for e-signature, so that provider's field markers are printed. */
        global String signProviderName;
    }

    global class Result {
        @AuraEnabled
        global Boolean success;
        /** The GeneratedDocument__c record, created for successes and failures alike. */
        @AuraEnabled
        global Id documentId;
        @AuraEnabled
        global Id contentVersionId;
        @AuraEnabled
        global Id contentDocumentId;
        @AuraEnabled
        global String fileName;
        @AuraEnabled
        global String emailStatus;
        /** The template's signature request subject and message, with fields filled in for this record. */
        @AuraEnabled
        global String signSubject;
        @AuraEnabled
        global String signMessage;
        @AuraEnabled
        global String errorMessage;
        /** The signers defined on the template, resolved for this record. */
        @AuraEnabled
        global List<DocBuilderSign.Signer> signers;
    }

    global static Result generate(Request request) {
        return DocBuilderEngine.run(request);
    }

    global static List<Result> generate(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            results.add(DocBuilderEngine.run(request));
        }
        return results;
    }

    /**
     * Generates one document per record in the background and returns the DocGenJob__c Id,
     * which tracks progress. Each document is saved to Files on its own record.
     */
    global static Id generateInBackground(String templateName, List<Id> recordIds) {
        if (String.isBlank(templateName) || recordIds == null || recordIds.isEmpty()) {
            throw new DocBuilderException('A template name and at least one record ID are required.');
        }
        DocBuilderPolicy.checkBulk(recordIds.size());
        List<DocTemplate__c> templates = [SELECT Id FROM DocTemplate__c WHERE Name = :templateName WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1];
        if (templates.isEmpty()) {
            throw new DocBuilderException('No template named "' + templateName + '" is available to you.');
        }
        DocGenJob__c job = new DocGenJob__c(
            Template__c = templates[0].Id,
            Template_Name__c = templateName.left(80),
            Total__c = recordIds.size(),
            Succeeded__c = 0,
            Failed__c = 0,
            Status__c = 'Queued',
            Started_On__c = System.now()
        );
        DocBuilderStore.insertRecord(job);
        System.enqueueJob(new DocBuilderBulkJob(job.Id, templateName, recordIds, 0));
        return job.Id;
    }
}
