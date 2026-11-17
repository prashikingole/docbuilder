/**
 * Server side of the Template Designer: template and version lifecycle, schema lookups for the
 * field picker, live preview, health check and translations.
 */
public with sharing class DocBuilderDesignerController {
    public class TemplateState {
        @AuraEnabled
        public Id templateId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String baseObject;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String fileNamePattern;
        @AuraEnabled
        public String languages;
        @AuraEnabled
        public String defaultLanguage;
        @AuraEnabled
        public Id versionId;
        @AuraEnabled
        public Decimal versionNumber;
        @AuraEnabled
        public String versionStatus;
        @AuraEnabled
        public Decimal activeVersionNumber;
        @AuraEnabled
        public String bodyJson;
    }

    public class FieldInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String type;
        @AuraEnabled
        public String relationshipName;
        @AuraEnabled
        public String referenceTo;
        /** Active picklist values, so rules offer a list to choose from instead of free typing. */
        @AuraEnabled
        public List<String> values;
    }

    public class ChildInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String childObject;
        /** Plural label of the child object, e.g. Opportunity Products. */
        @AuraEnabled
        public String label;
        /** The lookup field on the child that points back to the parent. */
        @AuraEnabled
        public String field;
    }

    public class ObjectInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public List<FieldInfo> fields = new List<FieldInfo>();
        @AuraEnabled
        public List<ChildInfo> children = new List<ChildInfo>();
    }

    @AuraEnabled
    public static List<DocTemplate__c> listTemplates() {
        return [SELECT Id, Name, Base_Object__c, Status__c FROM DocTemplate__c WITH USER_MODE ORDER BY Name LIMIT 500];
    }

    @AuraEnabled
    public static TemplateState createTemplate(String name, String baseObject) {
        try {
            if (String.isBlank(name) || String.isBlank(baseObject)) {
                throw new DocBuilder.DocBuilderException('A name and an object are required.');
            }
            Schema.DescribeSObjectResult described = describe(baseObject);
            DocTemplate__c template = new DocTemplate__c(Name = name.trim().left(80), Base_Object__c = described.getName(), Status__c = 'Draft', Default_Language__c = 'en');
            insert as user template;
            insert as user new DocTemplateVersion__c(Template__c = template.Id, Version_Number__c = 1, Status__c = 'Draft', Body_JSON__c = '{"blocks":[],"calculations":[]}');
            return loadTemplate(template.Id);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Loads the draft version if there is one, otherwise the active version. */
    @AuraEnabled
    public static TemplateState loadTemplate(Id templateId) {
        DocTemplate__c template = [
            SELECT Id, Name, Base_Object__c, Status__c, File_Name_Pattern__c, Languages__c, Default_Language__c, Active_Version__c, Active_Version__r.Version_Number__c
            FROM DocTemplate__c
            WHERE Id = :templateId
            WITH USER_MODE
        ];
        TemplateState state = new TemplateState();
        state.templateId = template.Id;
        state.name = template.Name;
        state.baseObject = template.Base_Object__c;
        state.status = template.Status__c;
        state.fileNamePattern = template.File_Name_Pattern__c;
        state.languages = template.Languages__c;
        state.defaultLanguage = template.Default_Language__c;
        state.activeVersionNumber = template.Active_Version__c == null ? null : template.Active_Version__r.Version_Number__c;

        DocTemplateVersion__c version = draftOf(templateId);
        if (version == null && template.Active_Version__c != null) {
            version = [SELECT Id, Version_Number__c, Status__c, Body_JSON__c FROM DocTemplateVersion__c WHERE Id = :template.Active_Version__c WITH USER_MODE];
        }
        if (version != null) {
            state.versionId = version.Id;
            state.versionNumber = version.Version_Number__c;
            state.versionStatus = version.Status__c;
            state.bodyJson = version.Body_JSON__c;
        }
        return state;
    }

    /** Saves into the current draft, or starts a new draft version when the latest version is active. */
    @AuraEnabled
    public static TemplateState saveDraft(Id templateId, String name, String fileNamePattern, String languages, String bodyJson) {
        try {
            JSON.deserializeUntyped(bodyJson);
            DocTemplate__c template = [SELECT Id, Active_Version__c FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE FOR UPDATE];
            if (String.isNotBlank(name)) {
                template.Name = name.trim().left(80);
            }
            template.File_Name_Pattern__c = fileNamePattern;
            template.Languages__c = languages;
            update as user template;

            DocTemplateVersion__c draft = draftOf(templateId);
            if (draft != null) {
                draft.Body_JSON__c = bodyJson;
                update as user draft;
            } else {
                AggregateResult latest = [SELECT MAX(Version_Number__c) maxVersion FROM DocTemplateVersion__c WHERE Template__c = :templateId WITH USER_MODE];
                Decimal nextNumber = latest.get('maxVersion') == null ? 1 : (Decimal) latest.get('maxVersion') + 1;
                draft = new DocTemplateVersion__c(Template__c = templateId, Version_Number__c = nextNumber, Status__c = 'Draft', Body_JSON__c = bodyJson);
                insert as user draft;
                // Carry translations forward so a new version does not start untranslated.
                if (template.Active_Version__c != null) {
                    List<DocTranslation__c> copies = new List<DocTranslation__c>();
                    for (DocTranslation__c t : [
                        SELECT Language__c, Block_Id__c, Part__c, Source_Text__c, Translated_Text__c
                        FROM DocTranslation__c
                        WHERE Template_Version__c = :template.Active_Version__c
                        WITH USER_MODE
                    ]) {
                        DocTranslation__c copy = t.clone(false, true);
                        copy.Template_Version__c = draft.Id;
                        copies.add(copy);
                    }
                    insert as user copies;
                }
            }
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Makes the draft the active version. The previous active version is archived, never deleted. */
    @AuraEnabled
    public static TemplateState activate(Id templateId) {
        try {
            DocTemplate__c template = [SELECT Id, Base_Object__c, Active_Version__c FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE FOR UPDATE];
            DocTemplateVersion__c draft = draftOf(templateId);
            if (draft == null) {
                throw new DocBuilder.DocBuilderException('There is no draft to activate. Save a change first.');
            }
            String problem = check(draft.Body_JSON__c, template.Base_Object__c);
            if (problem != null) {
                throw new DocBuilder.DocBuilderException('This template cannot be activated yet. ' + problem);
            }
            List<DocTemplateVersion__c> changes = new List<DocTemplateVersion__c>();
            if (template.Active_Version__c != null) {
                changes.add(new DocTemplateVersion__c(Id = template.Active_Version__c, Status__c = 'Archived'));
            }
            changes.add(new DocTemplateVersion__c(Id = draft.Id, Status__c = 'Active', Activated_On__c = System.now()));
            update as user changes;
            template.Active_Version__c = draft.Id;
            template.Status__c = 'Active';
            update as user template;
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    static DocTemplateVersion__c draftOf(Id templateId) {
        List<DocTemplateVersion__c> drafts = [
            SELECT Id, Version_Number__c, Status__c, Body_JSON__c
            FROM DocTemplateVersion__c
            WHERE Template__c = :templateId AND Status__c = 'Draft'
            WITH USER_MODE
            ORDER BY Version_Number__c DESC
            LIMIT 1
        ];
        return drafts.isEmpty() ? null : drafts[0];
    }

    static Schema.DescribeSObjectResult describe(String objectName) {
        try {
            return Schema.describeSObjects(new List<String>{ objectName.trim() })[0];
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('"' + objectName + '" is not an object in this org. Use its API name, for example Opportunity.');
        }
    }

    /** Fields and child lists of an object, limited to what the current user can read. */
    @AuraEnabled(cacheable=true)
    public static ObjectInfo describeObject(String objectName) {
        try {
            Schema.DescribeSObjectResult described = describe(objectName);
            ObjectInfo info = new ObjectInfo();
            info.name = described.getName();
            info.label = described.getLabel();
            for (Schema.SObjectField f : described.fields.getMap().values()) {
                Schema.DescribeFieldResult d = f.getDescribe();
                if (!d.isAccessible()) {
                    continue;
                }
                FieldInfo field = new FieldInfo();
                field.name = d.getName();
                field.label = d.getLabel();
                field.type = String.valueOf(d.getType()).toLowerCase().capitalize();
                if (d.getType() == Schema.DisplayType.REFERENCE && d.getRelationshipName() != null && !d.getReferenceTo().isEmpty()) {
                    field.relationshipName = d.getRelationshipName();
                    field.referenceTo = String.valueOf(d.getReferenceTo()[0]);
                }
                if (d.getType() == Schema.DisplayType.PICKLIST || d.getType() == Schema.DisplayType.MULTIPICKLIST) {
                    field.values = new List<String>();
                    for (Schema.PicklistEntry entry : d.getPicklistValues()) {
                        if (entry.isActive() && field.values.size() < 300) {
                            field.values.add(entry.getValue());
                        }
                    }
                }
                info.fields.add(field);
            }
            for (Schema.ChildRelationship rel : described.getChildRelationships()) {
                if (rel.getRelationshipName() == null) {
                    continue;
                }
                ChildInfo child = new ChildInfo();
                child.name = rel.getRelationshipName();
                child.childObject = String.valueOf(rel.getChildSObject());
                child.label = rel.getChildSObject().getDescribe().getLabelPlural();
                child.field = String.valueOf(rel.getField());
                info.children.add(child);
            }
            return info;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static String preview(String bodyJson, String baseObject, Id recordId, Id versionId, String language) {
        try {
            return DocBuilderEngine.previewHtml(bodyJson, baseObject, recordId, versionId, language);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    public class CalcResult {
        @AuraEnabled
        public Boolean ok;
        /** Calculated value name -> its value as it would print. */
        @AuraEnabled
        public Map<String, String> values = new Map<String, String>();
        @AuraEnabled
        public String message;
    }

    /** Works out every calculated value of an unsaved template for one record, for the live result next to a formula. */
    @AuraEnabled
    public static CalcResult calcValues(String bodyJson, String baseObject, Id recordId) {
        CalcResult result = new CalcResult();
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(bodyJson);
            DocBuilderContext ctx = new DocBuilderContext(baseObject, recordId, body, null);
            ctx.load();
            for (String name : ctx.calcs.keySet()) {
                result.values.put(name, ctx.formatCalc(name, null));
            }
            result.ok = true;
        } catch (Exception e) {
            result.ok = false;
            result.message = e.getMessage();
        }
        return result;
    }

    /** Every signature provider row with whether it is switched on. */
    @AuraEnabled
    public static List<DocBuilderSign.ProviderStatus> listProviders() {
        return DocBuilderSign.allProviders();
    }

    public class ConnectionResult {
        @AuraEnabled
        public Boolean ok;
        @AuraEnabled
        public String message;
    }

    /**
     * Tries a provider's connection without sending anything. Admin-only (this class is only in the
     * DocBuilder Admin permission set), so the provider's own error text is shown to help set-up.
     */
    @AuraEnabled
    public static ConnectionResult testProvider(String providerName) {
        ConnectionResult result = new ConnectionResult();
        try {
            result.message = DocBuilderSign.testConnection(providerName);
            result.ok = true;
        } catch (DocBuilderSignHttp.ProviderException e) {
            result.ok = false;
            result.message = e.getMessage() + (e.detail == null ? '' : ' ' + e.detail.left(300));
        } catch (Exception e) {
            result.ok = false;
            result.message = e.getMessage();
        }
        return result;
    }

    /** Health check: returns null when every field the template uses exists and is readable, otherwise the problem. */
    @AuraEnabled
    public static String check(String bodyJson, String baseObject) {
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(bodyJson);
            DocBuilderPrepare.apply(body, null, null);
            return new DocBuilderContext(baseObject, null, body, null).check();
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    @AuraEnabled
    public static List<DocBuilderPrepare.TextPart> getTranslations(Id versionId, String language) {
        DocTemplateVersion__c version = [SELECT Body_JSON__c FROM DocTemplateVersion__c WHERE Id = :versionId WITH USER_MODE];
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(version.Body_JSON__c);
        return DocBuilderPrepare.parts(body, versionId, language);
    }

    /** Replaces the translations of one version and language. itemsJson is a list of { blockId, part, source, translated }. */
    @AuraEnabled
    public static void saveTranslations(Id versionId, String language, String itemsJson) {
        try {
            if (String.isBlank(language)) {
                throw new DocBuilder.DocBuilderException('Choose a language first.');
            }
            delete as user [SELECT Id FROM DocTranslation__c WHERE Template_Version__c = :versionId AND Language__c = :language WITH USER_MODE];
            List<DocTranslation__c> rows = new List<DocTranslation__c>();
            for (Object o : (List<Object>) JSON.deserializeUntyped(itemsJson)) {
                Map<String, Object> item = (Map<String, Object>) o;
                String translated = (String) item.get('translated');
                if (String.isBlank(translated)) {
                    continue;
                }
                rows.add(
                    new DocTranslation__c(
                        Template_Version__c = versionId,
                        Language__c = language.trim().left(10),
                        Block_Id__c = (String) item.get('blockId'),
                        Part__c = (String) item.get('part'),
                        Source_Text__c = (String) item.get('source'),
                        Translated_Text__c = translated
                    )
                );
            }
            insert as user rows;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}
