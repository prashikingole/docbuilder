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

    /** Providers a test treats as switched off (provider rows cannot be changed in a test). */
    @TestVisible
    static Set<String> testInactive = new Set<String>();

    /**
     * Whether new requests may go through this provider. In Apex tests the Test provider always counts as
     * switched on, because provider rows cannot be created there and an org may have switched it off.
     */
    static Boolean isActive(String providerName) {
        if (testInactive.contains(providerName)) {
            return false;
        }
        if (Test.isRunningTest() && providerName == 'TestProvider') {
            return true;
        }
        List<DocSignProvider__mdt> found = rows(providerName);
        return !found.isEmpty() && found[0].Active__c == true;
    }

    public static List<ProviderOption> activeProviders() {
        List<ProviderOption> options = new List<ProviderOption>();
        List<DocSignProvider__mdt> active = new List<DocSignProvider__mdt>();
        Boolean hasTestProvider = false;
        for (DocSignProvider__mdt row : rows(null)) {
            if (!testInactive.contains(row.DeveloperName)) {
                active.add(row);
                hasTestProvider = hasTestProvider || row.DeveloperName == 'TestProvider';
            }
        }
        if (Test.isRunningTest() && !hasTestProvider && !testInactive.contains('TestProvider')) {
            active.addAll(rows('TestProvider'));
        }
        for (DocSignProvider__mdt row : active) {
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
        // testSettings is private and @TestVisible, so only test code can fill it.
        if (!testSettings.isEmpty() && testSettings.containsKey(providerName)) {
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

    /** Every provider row, active or not, for the admin's provider list. */
    public class ProviderStatus {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Boolean active;
        @AuraEnabled
        public String namedCredential;
    }

    public static List<ProviderStatus> allProviders() {
        List<ProviderStatus> result = new List<ProviderStatus>();
        for (DocSignProvider__mdt row : [
            SELECT DeveloperName, MasterLabel, Active__c, Named_Credential__c
            FROM DocSignProvider__mdt
            ORDER BY Sort_Order__c NULLS LAST, MasterLabel
        ]) {
            ProviderStatus status = new ProviderStatus();
            status.name = row.DeveloperName;
            status.label = row.MasterLabel;
            status.active = row.Active__c;
            status.namedCredential = row.Named_Credential__c;
            result.add(status);
        }
        return result;
    }

    /**
     * Checks that a provider is reachable and signed in, without sending anything. Works whether or not the
     * provider is active, so admins can test before switching it on. Returns a plain description of the result.
     */
    global static String testConnection(String providerName) {
        ProviderConfig config = configFor(providerName);
        DocBuilderSignProvider provider = providerFor(providerName);
        if (!(provider instanceof DocBuilderSignCheck)) {
            return config.label + ' has no connection test. Send a document to check it.';
        }
        return ((DocBuilderSignCheck) provider).check(config);
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
        // New requests only go through providers an admin has switched on. Requests already sent keep
        // being checked and can still be withdrawn after their provider is switched off.
        providerFor(request.providerName);
        if (!isActive(request.providerName)) {
            throw new DocBuilder.DocBuilderException('The signature provider "' + request.providerName + '" is not switched on. Ask your admin to activate it.');
        }

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
        Integer checked = 0;
        for (Signer signer : signers) {
            checked++;
            if (String.isBlank(signer.email)) {
                String who = String.isNotBlank(signer.name) ? signer.name : (String.isNotBlank(signer.role) ? signer.role : 'Signer ' + checked);
                throw new DocBuilder.DocBuilderException(who + ' has no email address. Fill it in, or check the field it comes from on this record.');
            }
        }

        DocSignRequest__c record = new DocSignRequest__c(
            Generated_Document__c = generated.documentId,
            Provider__c = request.providerName,
            Status__c = 'Queued',
            Record_Id__c = request.recordId,
            File_Name__c = generated.fileName,
            Subject__c = String.isNotBlank(request.subject)
                ? request.subject.left(255)
                : (String.isNotBlank(generated.signSubject) ? generated.signSubject.left(255) : ('Please sign: ' + generated.fileName.removeEnd('.pdf')).left(255)),
            Message__c = String.isNotBlank(request.message) ? request.message : generated.signMessage,
            Unsigned_Content_Version_Id__c = generated.contentVersionId
        );
        DocBuilderStore.insertRecord(record);

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
        DocBuilderStore.insertRecords(rows);

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
        public String errorDetail;
    }

    /** Loads requests for background work. User-facing callers must check access first (see refresh and cancel). */
    public static List<DocSignRequest__c> loadRequests(Set<Id> ids) {
        return DocBuilderStore.loadRequests(ids);
    }

    /** Confirms, with the user's own access, that they can see this request. */
    static Boolean canSee(Id signatureRequestId) {
        return ![SELECT Id FROM DocSignRequest__c WHERE Id = :signatureRequestId WITH USER_MODE LIMIT 1].isEmpty();
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
            outcome.error = DocBuilderSignHttp.userMessage(e);
            outcome.errorDetail = DocBuilderSignHttp.detailOf(e);
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
        Map<Id, ContentVersion> unsigned = DocBuilderStore.fileData(unsignedIds);

        for (Outcome outcome : outcomes) {
            DocSignRequest__c request = new DocSignRequest__c(Id = outcome.request.Id, Last_Checked_On__c = System.now());
            requests.add(request);
            if (outcome.error != null) {
                request.Error_Message__c = outcome.error.left(32000);
                request.Error_Detail__c = outcome.errorDetail == null ? null : outcome.errorDetail.left(32000);
                continue;
            }
            if (outcome.status == null || String.isBlank(outcome.status.status)) {
                continue;
            }
            request.Status__c = outcome.status.status;
            request.Error_Message__c = null;
            request.Error_Detail__c = null;
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

        DocBuilderStore.insertRecords(signedCopies.values());
        for (DocSignRequest__c request : requests) {
            if (signedCopies.containsKey(request.Id)) {
                request.Signed_Content_Version_Id__c = signedCopies.get(request.Id).Id;
            }
        }
        DocBuilderStore.updateRecords(signers);
        DocBuilderStore.updateRecords(requests);
    }

    /** Checks one request with its provider now and saves the result. Does nothing for a request the user cannot see. */
    global static void refresh(Id signatureRequestId) {
        if (signatureRequestId == null || !canSee(signatureRequestId)) {
            return;
        }
        List<DocSignRequest__c> found = loadRequests(new Set<Id>{ signatureRequestId });
        if (found.isEmpty() || String.isBlank(found[0].External_Id__c)) {
            return;
        }
        apply(new List<Outcome>{ collect(found[0]) });
    }

    /** Withdraws a request at the provider and marks it Voided. */
    global static void cancel(Id signatureRequestId, String reason) {
        if (signatureRequestId == null || !canSee(signatureRequestId)) {
            throw new DocBuilder.DocBuilderException('This signature request does not exist or you do not have access to it.');
        }
        DocSignRequest__c request = loadRequests(new Set<Id>{ signatureRequestId })[0];
        if (String.isNotBlank(request.External_Id__c)) {
            providerFor(request.Provider__c).cancel(configFor(request.Provider__c), request.External_Id__c, String.isBlank(reason) ? 'Withdrawn by sender' : reason);
        }
        DocBuilderStore.updateRecord(new DocSignRequest__c(Id = request.Id, Status__c = 'Voided', Last_Checked_On__c = System.now()));
    }
}
