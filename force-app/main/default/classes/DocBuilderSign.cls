/**
 * Public API for e-signature. Works with any provider registered as a Signature Provider row.
 *
 *   DocBuilderSign.SendRequest req = new DocBuilderSign.SendRequest();
 *   req.templateId = templateId;
 *   req.recordId = opportunityId;
 *   req.providerName = 'DocuSign';
 *   Id signatureRequestId = DocBuilderSign.send(req);
 */
global with sharing class DocBuilderSign {
    global class Signer {
        @AuraEnabled
        global String role;
        @AuraEnabled
        global String name;
        @AuraEnabled
        global String email;
        @AuraEnabled
        global Integer routingOrder;
    }

    /** One Signature Provider row, handed to the provider class on every call. */
    global class ProviderConfig {
        global String name;
        global String label;
        /** API name of the Named Credential. Call out to 'callout:' + namedCredential + path. */
        global String namedCredential;
        /** The row's Settings JSON, parsed. Never null. */
        global Map<String, Object> settings = new Map<String, Object>();
    }

    global class Envelope {
        global ProviderConfig config;
        global String fileName;
        global Blob file;
        global String subject;
        global String message;
        global List<Signer> signers;
    }

    global class SendResult {
        global String externalId;
    }

    global class SignerStatus {
        global String email;
        /** Sent, Signed or Declined. */
        global String status;
        global Datetime signedOn;
    }

    global class StatusResult {
        /** Sent, Completed, Declined or Voided. */
        global String status;
        global List<SignerStatus> signers = new List<SignerStatus>();
    }

    global class SendRequest {
        global Id templateId;
        global List<Id> additionalTemplateIds;
        global Id recordId;
        global String language;
        /** Developer name of a Signature Provider row. */
        global String providerName;
        /** Optional. Overrides the signers defined on the template; keep the same order. */
        global List<Signer> signers;
        global String subject;
        global String message;
    }

    /** What the Generate dialog needs to draw a provider's button. */
    public class ProviderOption {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String customFlow;
        /** Which built-in signing screen opens first: form, steps or desk. */
        @AuraEnabled
        public String style;
    }

    // ---------- Registry ----------

    /** Provider rows cannot be created in a test, so tests supply settings here instead. */
    @TestVisible
    static Map<String, Map<String, Object>> testSettings = new Map<String, Map<String, Object>>();

    static List<DocSignProvider__mdt> rows(String name) {
        if (name == null) {
            return [
                SELECT DeveloperName, MasterLabel, Apex_Class__c, Named_Credential__c, Button_Label__c, Custom_Flow__c, Config_JSON__c, Active__c, Screen_Style__c
                FROM DocSignProvider__mdt
                WHERE Active__c = TRUE
                ORDER BY Sort_Order__c NULLS LAST, MasterLabel
            ];
        }
        return [
            SELECT DeveloperName, MasterLabel, Apex_Class__c, Named_Credential__c, Button_Label__c, Custom_Flow__c, Config_JSON__c, Active__c, Screen_Style__c
            FROM DocSignProvider__mdt
            WHERE DeveloperName = :name
        ];
    }

    public static List<ProviderOption> activeProviders() {
        List<ProviderOption> options = new List<ProviderOption>();
        for (DocSignProvider__mdt row : rows(null)) {
            ProviderOption option = new ProviderOption();
            option.name = row.DeveloperName;
            option.label = String.isBlank(row.Button_Label__c) ? 'Send with ' + row.MasterLabel : row.Button_Label__c;
            option.customFlow = row.Custom_Flow__c;
            String style = String.isBlank(row.Screen_Style__c) ? 'form' : row.Screen_Style__c.trim().toLowerCase();
            option.style = new Set<String>{ 'form', 'steps', 'desk' }.contains(style) ? style : 'form';
            options.add(option);
        }
        return options;
    }

    global static ProviderConfig configFor(String providerName) {
        List<DocSignProvider__mdt> found = rows(providerName);
        if (found.isEmpty()) {
            throw new DocBuilder.DocBuilderException('There is no signature provider named "' + providerName + '".');
        }
        DocSignProvider__mdt row = found[0];
        ProviderConfig config = new ProviderConfig();
        config.name = row.DeveloperName;
        config.label = row.MasterLabel;
        config.namedCredential = row.Named_Credential__c;
        if (String.isNotBlank(row.Config_JSON__c)) {
            try {
                config.settings = (Map<String, Object>) JSON.deserializeUntyped(row.Config_JSON__c);
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('The Settings JSON of signature provider "' + providerName + '" is not valid JSON.');
            }
        }
        if (Test.isRunningTest() && testSettings.containsKey(providerName)) {
            config.settings = testSettings.get(providerName);
            config.namedCredential = 'Unit_Credential';
        }
        return config;
    }

    global static DocBuilderSignProvider providerFor(String providerName) {
        List<DocSignProvider__mdt> found = rows(providerName);
        if (found.isEmpty()) {
            throw new DocBuilder.DocBuilderException('There is no signature provider named "' + providerName + '".');
        }
        String className = found[0].Apex_Class__c;
        Type implementation = String.isBlank(className) ? null : (className.contains('.') ? Type.forName(className.substringBefore('.'), className.substringAfter('.')) : Type.forName(className));
        if (implementation == null) {
            throw new DocBuilder.DocBuilderException('Signature provider "' + providerName + '" names the Apex class "' + className + '", which does not exist.');
        }
        Object instance = implementation.newInstance();
        if (!(instance instanceof DocBuilderSignProvider)) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" does not implement DocBuilderSignProvider.');
        }
        return (DocBuilderSignProvider) instance;
    }

    // ---------- Sending ----------

    /**
     * Generates the document with the provider's signature markers, records a Signature Request
     * and queues the send. Returns the DocSignRequest__c Id. The call to the provider happens in
     * the background, because Salesforce does not allow it in the same step as saving records.
     */
    global static Id send(SendRequest request) {
        if (request == null || request.recordId == null || request.templateId == null || String.isBlank(request.providerName)) {
            throw new DocBuilder.DocBuilderException('A template, a record and a signature provider are required.');
        }
        providerFor(request.providerName);

        DocBuilder.Request generate = new DocBuilder.Request();
        generate.templateId = request.templateId;
        generate.additionalTemplateIds = request.additionalTemplateIds;
        generate.recordId = request.recordId;
        generate.language = request.language;
        generate.signProviderName = request.providerName;
        generate.signers = request.signers;
        // Only the signed copy is attached to the record.
        generate.saveToRecord = false;
        DocBuilder.Result generated = DocBuilder.generate(generate);
        if (generated.success != true) {
            throw new DocBuilder.DocBuilderException(generated.errorMessage);
        }

        List<Signer> signers = request.signers != null && !request.signers.isEmpty() ? request.signers : generated.signers;
        if (signers == null || signers.isEmpty()) {
            throw new DocBuilder.DocBuilderException('This template has no signers. Add them under Signers in the Template Designer.');
        }
        for (Signer signer : signers) {
            if (String.isBlank(signer.email)) {
                throw new DocBuilder.DocBuilderException('Signer "' + (String.isBlank(signer.role) ? signer.name : signer.role) + '" has no email address.');
            }
        }

        DocSignRequest__c record = new DocSignRequest__c(
            Generated_Document__c = generated.documentId,
            Provider__c = request.providerName,
            Status__c = 'Queued',
            Record_Id__c = request.recordId,
            File_Name__c = generated.fileName,
            Subject__c = String.isBlank(request.subject) ? ('Please sign: ' + generated.fileName.removeEnd('.pdf')).left(255) : request.subject.left(255),
            Message__c = request.message,
            Unsigned_Content_Version_Id__c = generated.contentVersionId
        );
        insert record;

        List<DocSigner__c> rows = new List<DocSigner__c>();
        Integer position = 0;
        for (Signer signer : signers) {
            position++;
            rows.add(
                new DocSigner__c(
                    Sign_Request__c = record.Id,
                    Signer_Name__c = String.isBlank(signer.name) ? signer.email : signer.name.left(255),
                    Email__c = signer.email.trim(),
                    Role__c = signer.role == null ? null : signer.role.left(80),
                    Routing_Order__c = signer.routingOrder == null ? position : signer.routingOrder,
                    Status__c = 'Pending'
                )
            );
        }
        insert rows;

        System.enqueueJob(new DocBuilderSignJob(record.Id));
        return record.Id;
    }

    // ---------- Status ----------

    /** Everything learned from the provider about one request. Gathered before any record is saved. */
    public class Outcome {
        public DocSignRequest__c request;
        public StatusResult status;
        public Blob signedFile;
        public Boolean fetched = false;
        public String error;
    }

    static final String REQUEST_FIELDS = 'Id, Provider__c, External_Id__c, Status__c, Record_Id__c, File_Name__c, Unsigned_Content_Version_Id__c, Signed_Content_Version_Id__c';

    public static List<DocSignRequest__c> loadRequests(Set<Id> ids) {
        return Database.query('SELECT ' + REQUEST_FIELDS + ', (SELECT Id, Email__c, Status__c FROM Signers__r) FROM DocSignRequest__c WHERE Id IN :ids');
    }

    /** Asks the provider for the latest status. Makes callouts and saves nothing. */
    public static Outcome collect(DocSignRequest__c request) {
        Outcome outcome = new Outcome();
        outcome.request = request;
        try {
            ProviderConfig config = configFor(request.Provider__c);
            DocBuilderSignProvider provider = providerFor(request.Provider__c);
            outcome.status = provider.getStatus(config, request.External_Id__c);
            if (outcome.status != null && outcome.status.status == 'Completed' && request.Signed_Content_Version_Id__c == null) {
                outcome.signedFile = provider.download(config, request.External_Id__c);
                outcome.fetched = true;
            }
        } catch (Exception e) {
            outcome.error = e.getMessage();
        }
        return outcome;
    }

    /** Saves what collect() found: signer and request status, and the signed copy on the source record. */
    public static void apply(List<Outcome> outcomes) {
        List<DocSignRequest__c> requests = new List<DocSignRequest__c>();
        List<DocSigner__c> signers = new List<DocSigner__c>();
        Map<Id, ContentVersion> signedCopies = new Map<Id, ContentVersion>();
        Set<Id> unsignedIds = new Set<Id>();
        for (Outcome outcome : outcomes) {
            if (outcome.fetched && outcome.signedFile == null && outcome.request.Unsigned_Content_Version_Id__c != null) {
                unsignedIds.add(outcome.request.Unsigned_Content_Version_Id__c);
            }
        }
        Map<Id, ContentVersion> unsigned = new Map<Id, ContentVersion>([SELECT Id, VersionData FROM ContentVersion WHERE Id IN :unsignedIds]);

        for (Outcome outcome : outcomes) {
            DocSignRequest__c request = new DocSignRequest__c(Id = outcome.request.Id, Last_Checked_On__c = System.now());
            requests.add(request);
            if (outcome.error != null) {
                request.Error_Message__c = outcome.error.left(32000);
                continue;
            }
            if (outcome.status == null || String.isBlank(outcome.status.status)) {
                continue;
            }
            request.Status__c = outcome.status.status;
            request.Error_Message__c = null;
            Boolean completed = outcome.status.status == 'Completed';
            if (completed && outcome.request.Status__c != 'Completed') {
                request.Completed_On__c = System.now();
            }

            Map<String, SignerStatus> byEmail = new Map<String, SignerStatus>();
            for (SignerStatus s : outcome.status.signers) {
                if (s.email != null) {
                    byEmail.put(s.email.toLowerCase(), s);
                }
            }
            for (DocSigner__c row : outcome.request.Signers__r) {
                SignerStatus reported = row.Email__c == null ? null : byEmail.get(row.Email__c.toLowerCase());
                String status = reported != null && String.isNotBlank(reported.status) ? reported.status : (completed ? 'Signed' : null);
                if (status != null && status != row.Status__c) {
                    signers.add(
                        new DocSigner__c(Id = row.Id, Status__c = status, Signed_On__c = status == 'Signed' ? (reported != null && reported.signedOn != null ? reported.signedOn : System.now()) : null)
                    );
                }
            }

            if (outcome.fetched) {
                Blob file = outcome.signedFile;
                if (file == null && unsigned.containsKey(outcome.request.Unsigned_Content_Version_Id__c)) {
                    file = unsigned.get(outcome.request.Unsigned_Content_Version_Id__c).VersionData;
                }
                if (file != null) {
                    String baseName = String.isBlank(outcome.request.File_Name__c) ? 'Document' : outcome.request.File_Name__c.removeEnd('.pdf');
                    ContentVersion copy = new ContentVersion(Title = baseName + ' - signed', PathOnClient = baseName + ' - signed.pdf', VersionData = file);
                    try {
                        copy.FirstPublishLocationId = (Id) outcome.request.Record_Id__c;
                    } catch (Exception e) {
                        copy.FirstPublishLocationId = null;
                    }
                    signedCopies.put(outcome.request.Id, copy);
                }
            }
        }

        insert signedCopies.values();
        for (DocSignRequest__c request : requests) {
            if (signedCopies.containsKey(request.Id)) {
                request.Signed_Content_Version_Id__c = signedCopies.get(request.Id).Id;
            }
        }
        update signers;
        update requests;
    }

    /** Checks one request with its provider now and saves the result. */
    global static void refresh(Id signatureRequestId) {
        List<DocSignRequest__c> found = loadRequests(new Set<Id>{ signatureRequestId });
        if (found.isEmpty() || String.isBlank(found[0].External_Id__c)) {
            return;
        }
        apply(new List<Outcome>{ collect(found[0]) });
    }

    /** Withdraws a request at the provider and marks it Voided. */
    global static void cancel(Id signatureRequestId, String reason) {
        DocSignRequest__c request = loadRequests(new Set<Id>{ signatureRequestId })[0];
        if (String.isNotBlank(request.External_Id__c)) {
            providerFor(request.Provider__c).cancel(configFor(request.Provider__c), request.External_Id__c, String.isBlank(reason) ? 'Withdrawn by sender' : reason);
        }
        update new DocSignRequest__c(Id = request.Id, Status__c = 'Voided', Last_Checked_On__c = System.now());
    }
}
