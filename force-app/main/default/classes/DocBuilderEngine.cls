/**
 * Orchestrates one generation: load the template(s), load the data as the running user,
 * render, convert to PDF, store the file, write the audit record and delivery log, optionally email.
 * All reads and rendering happen before any DML so the PDF conversion is never blocked.
 */
public with sharing class DocBuilderEngine {
    class Part {
        DocTemplate__c template;
        DocTemplateVersion__c version;
        DocBuilderContext ctx;
    }

    public static DocBuilder.Result run(DocBuilder.Request req) {
        DocBuilder.Result res = new DocBuilder.Result();
        res.success = false;

        List<Part> parts = new List<Part>();
        Blob file;
        String fileName;
        Boolean draft = req != null && req.draft == true;

        try {
            if (req == null || req.recordId == null) {
                throw new DocBuilder.DocBuilderException('A record ID is required.');
            }
            String recordObject = String.valueOf(req.recordId.getSObjectType());

            List<DocTemplate__c> templates = new List<DocTemplate__c>{ loadTemplate(req.templateId, req.templateName) };
            if (req.additionalTemplateIds != null) {
                for (Id extraId : req.additionalTemplateIds) {
                    templates.add(loadTemplate(extraId, null));
                }
            }

            List<String> bodies = new List<String>();
            for (DocTemplate__c template : templates) {
                Part part = new Part();
                part.template = template;
                parts.add(part);
                part.version = [SELECT Id, Version_Number__c, Body_JSON__c FROM DocTemplateVersion__c WHERE Id = :template.Active_Version__c];
                if (recordObject != template.Base_Object__c) {
                    throw new DocBuilder.DocBuilderException(
                        'Template "' + template.Name + '" is built on ' + template.Base_Object__c + ' but the record is a ' + recordObject + '.'
                    );
                }
                if (String.isBlank(part.version.Body_JSON__c)) {
                    throw new DocBuilder.DocBuilderException('The active version of "' + template.Name + '" has no content.');
                }
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(part.version.Body_JSON__c);
                DocBuilderPrepare.apply(body, part.version.Id, languageFor(req, template));
                part.ctx = new DocBuilderContext(template.Base_Object__c, req.recordId, body, template.File_Name_Pattern__c);
                part.ctx.signProvider = String.isBlank(req.signProviderName) ? null : DocBuilderSign.providerFor(req.signProviderName);
                part.ctx.signerOverrides = req.signers;
                part.ctx.load();
                bodies.add(DocBuilderRenderer.renderBody(part.ctx));
            }

            String html = DocBuilderRenderer.document(String.join(bodies, DocBuilderRenderer.PAGE_BREAK), draft, parts[0].ctx);
            // Blob.toPdf is not available in test context, so tests store the HTML itself.
            file = Test.isRunningTest() ? Blob.valueOf(html) : Blob.toPdf(html);
            fileName = buildFileName(parts[0].template, parts[0].ctx, draft);
        } catch (Exception e) {
            res.errorMessage = e.getMessage();
            res.documentId = logFailure(req, parts, e.getMessage());
            return res;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            ContentVersion cv = new ContentVersion(Title = fileName.removeEnd('.pdf'), PathOnClient = fileName, VersionData = file);
            if (req.saveToRecord != false) {
                cv.FirstPublishLocationId = req.recordId;
            }
            insert cv;
            cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

            Part first = parts[0];
            GeneratedDocument__c doc = new GeneratedDocument__c(
                Template__c = first.template.Id,
                Template_Version__c = first.version.Id,
                Record_Id__c = req.recordId,
                Object__c = first.template.Base_Object__c,
                Content_Version_Id__c = cv.Id,
                Content_Document_Id__c = cv.ContentDocumentId,
                File_Name__c = fileName,
                Status__c = 'Success',
                Channel__c = channelOf(req),
                Generated_On__c = System.now(),
                Language__c = languageFor(req, first.template),
                Is_Draft__c = draft,
                Job__c = req.jobId,
                Snapshot_JSON__c = snapshotOf(parts)
            );
            Boolean hasEmail = req.emailTo != null && !req.emailTo.isEmpty();
            String emailStatus = hasEmail ? sendEmail(req, cv.Id, fileName) : null;
            doc.Email_Status__c = emailStatus;
            insert doc;

            List<DocDelivery__c> deliveries = new List<DocDelivery__c>();
            if (req.saveToRecord != false) {
                deliveries.add(
                    new DocDelivery__c(Generated_Document__c = doc.Id, Type__c = 'File', Status__c = 'Done', Detail__c = 'Saved to Files on the source record', Sent_On__c = System.now())
                );
            }
            if (hasEmail) {
                deliveries.add(
                    new DocDelivery__c(
                        Generated_Document__c = doc.Id,
                        Type__c = 'Email',
                        Status__c = emailStatus.startsWith('Sent') ? 'Done' : 'Failed',
                        Recipient__c = String.join(req.emailTo, ', ').left(255),
                        Detail__c = emailStatus,
                        Sent_On__c = System.now()
                    )
                );
            }
            insert deliveries;

            res.success = true;
            res.documentId = doc.Id;
            res.contentVersionId = cv.Id;
            res.contentDocumentId = cv.ContentDocumentId;
            res.fileName = fileName;
            res.emailStatus = emailStatus;
            res.signers = first.ctx.resolveSigners();
        } catch (Exception e) {
            Database.rollback(sp);
            res.errorMessage = e.getMessage();
            res.documentId = logFailure(req, parts, e.getMessage());
        }
        return res;
    }

    /**
     * Renders a template body against a record and returns the HTML, without saving anything.
     * Used by the designer and the generate dialog for live preview.
     */
    public static String previewHtml(String bodyJson, String baseObject, Id recordId, Id versionId, String language) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(bodyJson);
        DocBuilderPrepare.apply(body, versionId, language);
        DocBuilderContext ctx = new DocBuilderContext(baseObject, recordId, body, null);
        ctx.load();
        return DocBuilderRenderer.preview(ctx);
    }

    static String languageFor(DocBuilder.Request req, DocTemplate__c template) {
        if (String.isBlank(req.language) || req.language == template.Default_Language__c) {
            return null;
        }
        return req.language.trim();
    }

    static DocTemplate__c loadTemplate(Id templateId, String templateName) {
        List<DocTemplate__c> found;
        if (templateId != null) {
            found = [
                SELECT Id, Name, Base_Object__c, File_Name_Pattern__c, Active_Version__c, Status__c, Default_Language__c
                FROM DocTemplate__c
                WHERE Id = :templateId
                LIMIT 1
            ];
        } else {
            found = [
                SELECT Id, Name, Base_Object__c, File_Name_Pattern__c, Active_Version__c, Status__c, Default_Language__c
                FROM DocTemplate__c
                WHERE Name = :templateName
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
        }
        if (found.isEmpty()) {
            throw new DocBuilder.DocBuilderException('No template found' + (templateName == null ? '.' : ' named "' + templateName + '".'));
        }
        DocTemplate__c template = found[0];
        if (template.Status__c != 'Active' || template.Active_Version__c == null) {
            throw new DocBuilder.DocBuilderException('Template "' + template.Name + '" is not active or has no active version.');
        }
        return template;
    }

    static String buildFileName(DocTemplate__c template, DocBuilderContext ctx, Boolean draft) {
        String name = String.isBlank(template.File_Name_Pattern__c) ? template.Name : ctx.mergeText(template.File_Name_Pattern__c, ctx.record, false);
        name = name.replaceAll('[\\\\/:*?"<>|\\r\\n]', ' ').normalizeSpace();
        if (String.isBlank(name)) {
            name = template.Name;
        }
        return name.left(200) + (draft ? ' - DRAFT' : '') + '.pdf';
    }

    static String snapshotOf(List<Part> parts) {
        if (parts.size() == 1) {
            return parts[0].ctx.snapshotJson(parts[0].template.Name, parts[0].version.Version_Number__c);
        }
        List<String> each = new List<String>();
        for (Part part : parts) {
            each.add(part.ctx.snapshotJson(part.template.Name, part.version.Version_Number__c));
        }
        String combined = '{"parts":[' + String.join(each, ',') + ']}';
        // Keep the JSON valid if it would not fit: fall back to the first template's snapshot.
        return combined.length() > 130000 ? each[0] : combined;
    }

    static String channelOf(DocBuilder.Request req) {
        Set<String> allowed = new Set<String>{ 'Apex', 'Button', 'Flow', 'Bulk' };
        return req != null && allowed.contains(req.channel) ? req.channel : 'Apex';
    }

    static String sendEmail(DocBuilder.Request req, Id contentVersionId, String fileName) {
        try {
            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setToAddresses(req.emailTo);
            message.setSubject(String.isBlank(req.emailSubject) ? fileName.removeEnd('.pdf') : req.emailSubject);
            message.setPlainTextBody(String.isBlank(req.emailBody) ? 'Please find the document attached.' : req.emailBody);
            message.setEntityAttachments(new List<String>{ contentVersionId });
            message.setSaveAsActivity(false);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
            return ('Sent to ' + String.join(req.emailTo, ', ')).left(255);
        } catch (Exception e) {
            return ('Failed: ' + e.getMessage()).left(255);
        }
    }

    static Id logFailure(DocBuilder.Request req, List<Part> parts, String message) {
        try {
            Part first = parts.isEmpty() ? null : parts[0];
            GeneratedDocument__c doc = new GeneratedDocument__c(
                Template__c = first == null ? null : first.template.Id,
                Template_Version__c = first == null || first.version == null ? null : first.version.Id,
                Record_Id__c = req == null ? null : req.recordId,
                Object__c = first == null ? null : first.template.Base_Object__c,
                Status__c = 'Failed',
                Channel__c = channelOf(req),
                Generated_On__c = System.now(),
                Job__c = req == null ? null : req.jobId,
                Error_Message__c = message == null ? null : message.left(32000)
            );
            insert doc;
            return doc.Id;
        } catch (Exception e) {
            return null;
        }
    }
}
