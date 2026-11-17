/**
 * Server side of the Generate Document button.
 */
public with sharing class DocBuilderController {
    @AuraEnabled(cacheable=true)
    public static List<DocTemplate__c> getTemplates(Id recordId) {
        String objectName = String.valueOf(recordId.getSObjectType());
        return [
            SELECT Id, Name, Description__c, Languages__c, Default_Language__c, Active_Version__r.Version_Number__c
            FROM DocTemplate__c
            WHERE Base_Object__c = :objectName AND Status__c = 'Active' AND Active_Version__c != NULL
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /** HTML preview of a template's active version for a record. Nothing is saved. */
    @AuraEnabled
    public static String preview(Id templateId, Id recordId, String language) {
        try {
            DocTemplate__c template = [
                SELECT Base_Object__c, Default_Language__c, Active_Version__c, Active_Version__r.Body_JSON__c
                FROM DocTemplate__c
                WHERE Id = :templateId
                WITH USER_MODE
            ];
            String lang = String.isBlank(language) || language == template.Default_Language__c ? null : language;
            return DocBuilderEngine.previewHtml(template.Active_Version__r.Body_JSON__c, template.Base_Object__c, recordId, template.Active_Version__c, lang);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ---------- E-signature ----------

    public class SignOptions {
        @AuraEnabled
        public List<DocBuilderSign.ProviderOption> providers = new List<DocBuilderSign.ProviderOption>();
        @AuraEnabled
        public List<DocBuilderSign.Signer> signers = new List<DocBuilderSign.Signer>();
    }

    /** The active signature providers, and the template's signers worked out for this record. */
    @AuraEnabled
    public static SignOptions getSignOptions(Id templateId, Id recordId) {
        SignOptions options = new SignOptions();
        options.providers = DocBuilderSign.activeProviders();
        if (templateId == null || options.providers.isEmpty()) {
            return options;
        }
        try {
            DocTemplate__c template = [SELECT Base_Object__c, Active_Version__r.Body_JSON__c FROM DocTemplate__c WHERE Id = :templateId];
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(template.Active_Version__r.Body_JSON__c);
            if (!DocBuilderContext.asList(body.get('signers')).isEmpty()) {
                // Only the signers are needed, so the rest of the template is left out of the query.
                DocBuilderContext ctx = new DocBuilderContext(template.Base_Object__c, recordId, new Map<String, Object>{ 'signers' => body.get('signers') }, null);
                ctx.load();
                options.signers = ctx.resolveSigners();
            }
        } catch (Exception e) {
            options.signers = new List<DocBuilderSign.Signer>();
        }
        return options;
    }

    @AuraEnabled
    public static Id sendForSignature(List<Id> templateIds, Id recordId, String language, String providerName, String signersJson, String subject, String message) {
        try {
            DocBuilderSign.SendRequest request = new DocBuilderSign.SendRequest();
            if (templateIds != null && !templateIds.isEmpty()) {
                request.templateId = templateIds[0];
                request.additionalTemplateIds = new List<Id>();
                for (Integer i = 1; i < templateIds.size(); i++) {
                    request.additionalTemplateIds.add(templateIds[i]);
                }
            }
            request.recordId = recordId;
            request.language = language;
            request.providerName = providerName;
            request.subject = subject;
            request.message = message;
            if (String.isNotBlank(signersJson)) {
                request.signers = (List<DocBuilderSign.Signer>) JSON.deserialize(signersJson, List<DocBuilderSign.Signer>.class);
            }
            return DocBuilderSign.send(request);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Everything the signature tracker shows about one request. */
    public class SignatureView {
        @AuraEnabled
        public DocSignRequest__c request;
        @AuraEnabled
        public List<DocSigner__c> signers = new List<DocSigner__c>();
        @AuraEnabled
        public String providerLabel;
        @AuraEnabled
        public String sentBy;
        @AuraEnabled
        public String templateName;
        @AuraEnabled
        public Id sentDocumentId;
        @AuraEnabled
        public Id signedDocumentId;
    }

    @AuraEnabled
    public static SignatureView getSignatureView(Id requestId) {
        SignatureView view = new SignatureView();
        view.request = [
            SELECT
                Id,
                Name,
                Status__c,
                Provider__c,
                External_Id__c,
                File_Name__c,
                Subject__c,
                Error_Message__c,
                Record_Id__c,
                Sent_On__c,
                Completed_On__c,
                Last_Checked_On__c,
                CreatedDate,
                CreatedBy.Name,
                Unsigned_Content_Version_Id__c,
                Signed_Content_Version_Id__c,
                Generated_Document__r.Template__r.Name,
                (SELECT Id, Signer_Name__c, Email__c, Role__c, Routing_Order__c, Status__c, Signed_On__c FROM Signers__r ORDER BY Routing_Order__c, Name)
            FROM DocSignRequest__c
            WHERE Id = :requestId
        ];
        view.signers = view.request.Signers__r;
        view.sentBy = view.request.CreatedBy.Name;
        view.templateName = view.request.Generated_Document__r == null ? null : view.request.Generated_Document__r.Template__r.Name;
        view.providerLabel = view.request.Provider__c;
        for (DocSignProvider__mdt row : [SELECT MasterLabel FROM DocSignProvider__mdt WHERE DeveloperName = :view.request.Provider__c]) {
            view.providerLabel = row.MasterLabel;
        }
        Set<String> fileIds = new Set<String>{ view.request.Unsigned_Content_Version_Id__c, view.request.Signed_Content_Version_Id__c };
        fileIds.remove(null);
        for (ContentVersion file : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :fileIds]) {
            if (file.Id == view.request.Signed_Content_Version_Id__c) {
                view.signedDocumentId = file.ContentDocumentId;
            } else {
                view.sentDocumentId = file.ContentDocumentId;
            }
        }
        return view;
    }

    /** Checks a request with its provider now, then returns the latest view of it. */
    @AuraEnabled
    public static SignatureView refreshSignature(Id requestId) {
        try {
            DocBuilderSign.refresh(requestId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return getSignatureView(requestId);
    }

    /** Withdraws a request that has not been completed. */
    @AuraEnabled
    public static SignatureView withdrawSignature(Id requestId, String reason) {
        try {
            DocBuilderSign.cancel(requestId, reason);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return getSignatureView(requestId);
    }

    /**
     * Generates one document from one or more templates. With several templates they are combined
     * into a single file in the order given.
     */
    @AuraEnabled
    public static DocBuilder.Result generate(List<Id> templateIds, Id recordId, String language, Boolean draft, String emailTo, String emailSubject, String emailBody) {
        DocBuilder.Request req = new DocBuilder.Request();
        if (templateIds != null && !templateIds.isEmpty()) {
            req.templateId = templateIds[0];
            req.additionalTemplateIds = new List<Id>();
            for (Integer i = 1; i < templateIds.size(); i++) {
                req.additionalTemplateIds.add(templateIds[i]);
            }
        }
        req.recordId = recordId;
        req.language = language;
        req.draft = draft == true;
        req.emailSubject = emailSubject;
        req.emailBody = emailBody;
        req.channel = 'Button';
        if (String.isNotBlank(emailTo)) {
            req.emailTo = new List<String>();
            for (String address : emailTo.split('[,;\\s]+')) {
                if (String.isNotBlank(address)) {
                    req.emailTo.add(address.trim());
                }
            }
        }
        return DocBuilder.generate(req);
    }
}
